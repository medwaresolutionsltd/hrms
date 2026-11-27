# Production hosting on Render (HTTPS)

Runbook for deploying Medware HR to [Render](https://render.com) on a subdomain of your existing domain. Render issues and renews the HTTPS certificate for you.

> **Status: written but not yet deployed or tested on Render.** The files were validated for syntax only (YAML parses, shell passes `bash -n`). Expect to fix small things on the first deploy, and do the first deploy to a throwaway "staging" copy before you put real payroll data in. Section 9 lists what is most likely to need adjusting.

## 1. Architecture

Render is not an obvious fit for Frappe: Frappe wants MariaDB and a filesystem shared between its processes, while Render has no managed MariaDB and a disk attaches to one service only. The design works around both limits:

| Render service | Type | What it runs |
|---|---|---|
| `medware-hr` | Web service (Docker, 2 GB plan) | **One container** running nginx, gunicorn, socket.io, the scheduler and a background worker, with a persistent disk at `sites/` |
| `medware-hr-db` | Private service (Docker image `mariadb:11.8`) | MariaDB with its own persistent disk. Reachable only inside your Render account |
| `medware-hr-redis` | Key Value (Redis-compatible) | Cache, job queue and realtime. Private network only |

```
Browser / Android PWA --HTTPS--> Render edge --HTTP--> nginx --> gunicorn (Frappe)
                                                         |--> socket.io
                       scheduler + worker --> Key Value (Redis)     all --> MariaDB (private)
```

Files:

| File | Purpose |
|---|---|
| `render.yaml` (repo root) | Render Blueprint describing the three services |
| `docker/production/Dockerfile` | Builds Frappe + ERPNext + this repo's HRMS, the desk assets and the PWA |
| `docker/production/entrypoint.sh` | On every start: refreshes assets onto the disk, applies config, creates the site (first start) or migrates it |
| `docker/production/nginx.conf`, `Procfile` | Reverse proxy and the process list |

Region: **Frankfurt** (Render has no African region; this is the closest with good latency).

## 2. Before you start

- Your repository must be reachable by Render: connect the `medwaresolutionsltd/hrms` GitHub repo in Render's dashboard. The Docker build copies this repo's `hrms-develop/` folder in, so what is deployed is exactly what is committed. **Commit and push first.**
- Decide the subdomain, for example `hr.yourdomain.co.ke`.
- You need access to the DNS settings of the parent domain.
- **Data protection:** this system holds employees' IDs, KRA PINs, salaries and bank details. Under the Kenya Data Protection Act 2019, check with your legal or compliance contact about registering with the ODPC and about transferring personal data outside Kenya (Render's servers are in Germany). This is not legal advice and I have not verified your obligations.

## 3. Deploy

1. In the Render dashboard choose **New → Blueprint**, select the repo, and point it at `render.yaml` at the repo root.
2. When prompted, enter the two secrets (they are `sync: false` in the Blueprint, so they never live in git):
   - `SITE_NAME`: your full subdomain, e.g. `hr.yourdomain.co.ke`. **It must match the domain you will use exactly.** It also becomes the Frappe site name.
   - `ADMIN_PASSWORD`: a strong, unique password for the `Administrator` account. Do not reuse the local-development password.
3. Apply. The first build is slow (it builds Frappe, ERPNext and both frontends). The database and Key Value store start first. The web service then waits for MariaDB, creates the site and installs ERPNext and HRMS (several minutes).
4. Watch the web service logs for `Creating site ...` and then gunicorn and nginx starting. The health check is `/api/method/ping`.

## 4. Custom domain and HTTPS

1. In the `medware-hr` service, open **Settings → Custom Domains** and add your subdomain.
2. In your DNS provider, add the **CNAME** record Render shows, pointing the subdomain at the service's `onrender.com` address.
3. Click **Verify** in Render. The certificate is issued automatically (usually within minutes) and renewed automatically.
4. Open `https://<your subdomain>/` and confirm the padlock. Plain `http://` is redirected to HTTPS by Render.

## 5. First-time setup in the app

1. Log in as `Administrator` with the password you chose.
2. Complete the setup wizard: country **Kenya**, currency **KES**, your company name. The wizard creates the company and default holiday list.
3. Apply the Kenya payroll rules. In the Render web service open **Shell** and run:

   ```bash
   cd /home/frappe/frappe-bench
   bench --site "$SITE_NAME" execute hrms.regional.kenya.setup.setup
   ```

   It is safe to run again at any time. Statutory rates must be verified by your payroll or tax professional before real payroll runs (see `MEDWARE_CUSTOMIZATION.md`).
4. Configure outgoing email (**Email Account**, outgoing) so password resets and notifications work. Use an SMTP provider such as Brevo, Mailgun, Amazon SES or your Google Workspace SMTP. Nothing can be emailed until this is set.
5. Create real user accounts and assign roles (HR Manager, HR User, Employee). Create employee records and link them to users so staff can use the mobile app.
6. Rotate or disable any shared accounts, and enable two-factor authentication for HR and System Manager users (**System Settings → Enable Two Factor Auth**).

## 6. Android and the PWA

- Open `https://<subdomain>/hrms` in Chrome on Android. After a moment Chrome offers **Install app** (or use the browser menu → *Install app*). It installs as a standalone app with the Medware icon.
- Installation requires HTTPS, a web manifest, icons and a service worker. All are present. Because Render serves real HTTPS, the install prompt now works on phones (it does not on plain `localhost`).
- Geolocation for attendance check-in works over HTTPS and asks the user for permission.
- **Push notifications are not configured.** They need a push relay or Firebase project configured in Frappe. Until then, users get in-app notifications only.
- I have not tested on a physical Android device. Do that on staging first: install, log in, check in with location, apply for leave, go offline and reopen.
- iOS needs Safari → Share → Add to Home Screen (the Android install prompt does not exist there).

## 7. Backups (critical)

Payroll data must be recoverable. Layer these:

1. **Frappe's automatic backups** run daily from the scheduler and are written to the `sites/<site>/private/backups` folder on the disk. They protect against bad edits but **not** against losing the disk.
2. **Render disk snapshots**: enable and check retention in the dashboard for both disks. Treat the MariaDB disk snapshot as a convenience, not your only copy.
3. **Off-site copy**: configure **S3 Backup Settings** in Frappe (any S3-compatible bucket, ideally in a different provider or region) so each backup is also uploaded elsewhere.
4. **Test a restore** on a staging copy before relying on it. An untested backup is not a backup.

## 8. Operations

| Task | How |
|---|---|
| Deploy an update | Push to the branch Render watches. Each start runs `bench migrate` |
| Roll back | Render dashboard → the service → *Deploys* → redeploy an earlier deploy (database migrations are not rolled back; restore a backup if a migration is the problem) |
| Rate change (PAYE/NSSF/...) | Edit `hrms/regional/kenya/data.py`, push, then run the Kenya `setup` command above |
| Open a console | Render service **Shell**, then `bench --site "$SITE_NAME" console` |
| Logs | Render dashboard → service → *Logs* |
| Scale up | Increase the web service plan first. Do not run more than one instance (the disk and the single-container design allow only one) |

## 9. Known risks and things to verify

These are the parts I could not test locally:

- **Never deployed**: the Dockerfile, entrypoint and Blueprint have not been built or run on Render. Do a staging deployment first.
- **Build time and memory**: building Frappe plus two Vite frontends needs a lot of memory. If the build runs out of memory or time, build the image elsewhere (GitHub Actions) and push it to a registry that Render pulls from.
- **MariaDB on a Render disk**: uses a `data` subfolder to avoid the `lost+found` problem. Confirm the database initialises and survives a restart before trusting it.
- **Single instance**: web, scheduler and worker share one container and one disk, so there is no high availability. A deploy causes a short outage.
- **Cost**: roughly the web service (2 GB), the database service, two disks and the Key Value store, on the order of tens of US dollars per month. Check Render's current pricing before applying the Blueprint; I did not verify prices.
- **Frappe `develop` branch**: this build tracks Frappe and ERPNext `develop` (version 17 dev), which is a moving target. For a real payroll system, pin to a released stable branch once your target version supports this fork. Use a tagged release rather than `develop`.
- **Push notifications, email, S3 backups, monitoring and a staging environment** are not set up.
