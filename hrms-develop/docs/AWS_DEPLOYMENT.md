# Deploying Medware HR on AWS

Runbook for running Medware HR in production on AWS with HTTPS on a subdomain of your own domain. The infrastructure is defined as code in `infra/aws/`, so it can be recreated, reviewed and changed safely.

> **Status: written, validated, not yet deployed.** `terraform validate` and `terraform fmt` pass, the Docker Compose file validates, and the first-boot script was rendered and syntax-checked. It has **not** been applied to a real AWS account, and the application image has **not** been built end to end. Do a first run with a throwaway domain and no real data, and read section 10 before relying on it.

## 1. Architecture

One EC2 server runs everything in Docker Compose. This is the standard, best-understood way to run Frappe, and it keeps HRMS fully separate from any other system (including your asset app).

```
Users / Android PWA --HTTPS--> Elastic IP --> Caddy (auto-HTTPS) --> app container
                                                                       |  nginx > gunicorn (Frappe/ERPNext/HRMS)
                                                                       |  socket.io, scheduler, worker
                                                          MariaDB <----+----> Redis
        encrypted EBS data disk (/data)  --daily snapshots-->  EBS snapshots (14 kept)
        daily bench backup --> private S3 bucket (versioned, encrypted, 365 days)
```

| Piece | Purpose |
|---|---|
| EC2 `t3.large` (Ubuntu 24.04), IMDSv2 only | Runs Docker Compose. No SSH: you connect through AWS Systems Manager Session Manager |
| Elastic IP | Stable public address for your DNS record |
| Encrypted EBS data disk (50 GB, `prevent_destroy`) | Database, uploads, Redis data, TLS certificates |
| Data Lifecycle Manager | Daily snapshots of the data disk |
| S3 backup bucket | Daily Frappe backups: private, encrypted, versioned, TLS-only, with expiry |
| SSM Parameter Store | Holds the generated database and admin passwords and the optional GitHub token (encrypted) |
| IAM instance role | Session Manager, read its own parameters, write to the backup bucket. Nothing else |
| CloudWatch alarm | Automatically recovers the instance onto healthy hardware if the host fails |
| Security group | Inbound 80 and 443 only |

Files: `infra/aws/terraform/` (infrastructure), `infra/aws/compose/` (what runs on the server: `docker-compose.yml`, `Caddyfile`, `backup.sh`, `deploy.sh`), `docker/production/` (the application image).

## 2. Prerequisites

- An AWS account with permission to create EC2, EBS, S3, IAM, SSM, DLM and CloudWatch resources. Use an IAM user or role, not the root account, and turn on MFA.
- **Region.** The default is `af-south-1` (Cape Town), the closest to Kenya. It is an *opt-in* region: enable it first under *Account settings → AWS Regions*, then wait a few minutes. If you would rather not, use `eu-west-1` (Ireland).
- Installed locally: [Terraform](https://developer.hashicorp.com/terraform/install) 1.6 or newer, the [AWS CLI](https://aws.amazon.com/cli/) configured with your credentials, and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- The code must be pushed to GitHub. The server builds from the repository, so **what is deployed is exactly what is committed**. If the repository is private, create a fine-grained GitHub token with read-only *Contents* access to it.
- DNS access for your domain, and a subdomain chosen (for example `hr.yourdomain.co.ke`).
- **Data protection.** The system holds employee IDs, KRA PINs, salaries and bank details. Check the Kenya Data Protection Act 2019 requirements (ODPC registration, and cross-border transfer rules if you host outside Kenya) with your legal or compliance contact. This is not legal advice.

## 3. Deploy

```bash
cd hrms-develop/infra/aws/terraform
cp terraform.tfvars.example terraform.tfvars     # edit: domain_name, region
export TF_VAR_git_token=...                       # only if the repository is private
terraform init
terraform plan                                    # read it: about 25 resources to create
terraform apply
```

Terraform prints the **Elastic IP**, the exact DNS record to create, and ready-made commands. Then:

1. **Create the DNS record** at your domain provider: an **A record** for your subdomain pointing at the Elastic IP. Caddy cannot get the HTTPS certificate until this resolves.
2. **Wait for the first boot** (20 to 40 minutes: it installs Docker, builds Frappe, ERPNext, HRMS and the mobile app, creates the database and the site). Watch it:

   ```bash
   aws ssm start-session --region <region> --target <instance-id>     # the connect_command output
   sudo tail -f /var/log/medware-bootstrap.log
   sudo docker compose -f /opt/medware/repo/hrms-develop/infra/aws/compose/docker-compose.yml logs -f app
   ```
3. When the app log shows the servers starting, open `https://<your subdomain>/`. The certificate is issued automatically within a minute or two of the DNS record resolving.

## 4. First-time setup in the app

1. Get the generated Administrator password with the `admin_password_command` output, log in as `Administrator`, and **change the password immediately**.
2. Complete the setup wizard: country **Kenya**, currency **KES**, your company name.
3. Apply the Kenya payroll rules (idempotent, safe to repeat):

   ```bash
   cd /opt/medware/repo/hrms-develop/infra/aws/compose
   sudo docker compose exec -T app bash -lc 'cd /home/frappe/frappe-bench && bench --site "$SITE_NAME" execute hrms.regional.kenya.setup.setup'
   ```

   The statutory rates in `hrms/regional/kenya/data.py` must be verified by your payroll or tax professional before real payroll runs (see `MEDWARE_CUSTOMIZATION.md`).
4. Set up outgoing email (**Email Account**, outgoing) with an SMTP provider (Amazon SES, Brevo, Mailgun or Google Workspace). Password resets and notifications do not work until this is done.
5. Create real user accounts, assign roles, create employee records and link them to users so staff can use the mobile app.
6. Enable two-factor authentication for HR and System Manager users (**System Settings**).

## 5. Android and the PWA

Open `https://<subdomain>/hrms` in Chrome on Android and choose **Install app**. Because the site is on real HTTPS, installation and geolocation for attendance check-in work. Push notifications are not configured (they need a push relay or Firebase project), so users get in-app notifications only. Test on a physical device before rollout: install, log in, check in with location, apply for leave, go offline and reopen. iOS uses Safari, Share, Add to Home Screen.

## 6. Backups and restore (critical)

Three independent layers:

1. **Daily Frappe backup to S3.** A root cron job runs `backup.sh` at 02:00 UTC (05:00 Nairobi). It runs `bench backup --with-files` and syncs the result to the S3 bucket, where each backup is kept for 365 days (`backup_retention_days`). Log: `/var/log/medware-backup.log`.
2. **Daily EBS snapshots** of the whole data disk, 14 kept (`snapshot_retention_count`).
3. **Versioned bucket**: an overwritten or deleted backup can be recovered for 30 days.

Run a backup by hand: `sudo /opt/medware/repo/hrms-develop/infra/aws/compose/backup.sh`.

**Restore from S3** (to the same or a rebuilt server):

```bash
cd /opt/medware/repo/hrms-develop/infra/aws/compose && set -a && . ./.env && set +a
sudo aws s3 ls s3://$BACKUP_BUCKET/frappe/$SITE_NAME/                        # pick a timestamp
sudo aws s3 sync s3://$BACKUP_BUCKET/frappe/$SITE_NAME/ /data/sites/$SITE_NAME/private/backups/ \
     --exclude "*" --include "<timestamp>*"
B=/home/frappe/frappe-bench/sites/$SITE_NAME/private/backups
sudo docker compose exec -T app bench --site "$SITE_NAME" restore \
     $B/<timestamp>-*-database.sql.gz \
     --with-public-files $B/<timestamp>-*-files.tar \
     --with-private-files $B/<timestamp>-*-private-files.tar \
     --db-root-password "$DB_ROOT_PASSWORD"
sudo docker compose exec -T app bench --site "$SITE_NAME" migrate
```

**Test a restore on a separate staging copy before you rely on it.** An untested backup is not a backup. Backups hold personal data: restrict who can read the bucket.

## 7. Operations

| Task | How |
|---|---|
| Deploy an update | Push to GitHub, then on the server `sudo .../compose/deploy.sh` (takes a backup first, pulls, rebuilds, restarts, migrates) |
| Roll back | `git checkout <earlier commit>` in `/opt/medware/repo`, `docker compose up -d --build`; restore a backup if a migration is the problem |
| Rate change (PAYE, NSSF, ...) | Edit `hrms/regional/kenya/data.py`, push, deploy, then run the Kenya `setup` command from section 4 |
| Logs | `sudo docker compose logs -f app` (also `db`, `caddy`). Container logs are size-limited |
| Restart | `sudo docker compose restart app` |
| Resize the server | Change `instance_type`, `terraform apply` (a short outage while the instance restarts) |
| Grow the data disk | Raise `data_volume_gb`, apply, then on the server `sudo resize2fs` the device |

## 8. Security notes

- There is no SSH and no open management port. Access is through Session Manager, audited in CloudTrail, controlled by IAM. Grant it only to people who need it.
- **Terraform state contains the generated passwords.** `terraform.tfstate` is gitignored, but for anything beyond a first trial, use the commented S3 backend in `versions.tf` (private, encrypted, versioned bucket) and restrict access to it.
- The server's `.env` is readable by root only. The GitHub token never touches the disk: it stays in SSM and is read at deploy time.
- Turn on AWS CloudTrail and billing alerts, and apply AWS account MFA.
- Keep the operating system patched: the host does not auto-reboot. Schedule `sudo apt-get update && sudo apt-get upgrade` regularly (or enable `unattended-upgrades`).
- The database and Redis are reachable only on the Docker network, never from the internet.

## 9. Cost

Recurring charges are the EC2 instance, the EBS disks (80 GB), the Elastic IP (AWS charges for public IPv4 addresses), EBS snapshots, S3 storage, and data transfer. I have not verified current prices, and Cape Town costs more than US and European regions. Use the [AWS Pricing Calculator](https://calculator.aws/) with a `t3.large`, 80 GB gp3 and a small S3 bucket before you apply. Set an AWS Budget alert.

## 10. Known risks and things to verify

- **Never applied to AWS and the image never built end to end.** Expect small fixes on the first run. The first build downloads Frappe, ERPNext and builds two frontends, so it needs reliable internet and enough memory; if it is killed for memory on a smaller instance, use a larger one.
- **Ubuntu image lookup.** The server image comes from Canonical's public SSM parameter. If your chosen region does not have it, `terraform plan` fails at that point: pick another region (such as `eu-west-1`) or set an AMI directly.
- **Frappe `develop` branch.** The image builds Frappe and ERPNext from `develop` (version 17 in development), a moving target. For real payroll, pin both to a stable release before go-live (`FRAPPE_BRANCH` and `ERPNEXT_BRANCH` build args in `docker/production/Dockerfile`).
- **Single server.** There is no high availability: a deploy or instance restart is a short outage. Host failure is recovered automatically, but the application is down for a few minutes meanwhile.
- **Protected resources.** The data disk has `prevent_destroy` and the instance has termination protection, so `terraform destroy` will refuse. To remove them deliberately, first take a backup, then remove `prevent_destroy` from the volume and `disable_api_termination` from the instance in `main.tf`, and apply.
- **Not set up yet:** outgoing email, push notifications, monitoring and alerting beyond host recovery, log shipping, a staging environment, and automatic OS patching.
