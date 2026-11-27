#!/bin/bash
# First-boot bootstrap for the Medware HR server (rendered by Terraform's templatefile).
# Only Terraform variables use the dollar-brace form here; bash variables are written as $NAME.
# Output is logged to /var/log/medware-bootstrap.log. The script is safe to re-run by hand.
set -euo pipefail   # no -x: tracing would write secrets into the log
exec > >(tee -a /var/log/medware-bootstrap.log) 2>&1

REGION="${region}"
PROJECT="${project}"
DOMAIN="${domain}"
REPO_URL="${repo_url}"
BRANCH="${repo_branch}"
BUCKET="${bucket}"
INSTALL_DIR=/opt/medware

export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin"

echo "=== 1/6 Installing Docker, Git and the AWS CLI"
apt-get update
apt-get install -y docker.io docker-compose-v2 git jq unzip
systemctl enable --now docker
snap install aws-cli --classic

echo "=== 2/6 Preparing the encrypted data disk"
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id_nodash}"
for i in $(seq 1 150); do
  [ -e "$DEV" ] && break
  echo "Waiting for the data disk to attach ($i/150)"
  sleep 2
done
[ -e "$DEV" ] || { echo "Data disk never appeared"; exit 1; }

# Format only a brand-new disk; never touch one that already holds data.
if ! blkid "$DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L medware-data "$DEV"
fi
mkdir -p /data
UUID="$(blkid -s UUID -o value "$DEV")"
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
mkdir -p /data/mariadb /data/redis /data/sites /data/caddy
chown -R 1000:1000 /data/sites   # the container's "frappe" user

echo "=== 3/6 Fetching secrets from SSM Parameter Store"
get() {
  aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$1" --with-decryption \
    --query Parameter.Value --output text
}
TOKEN="$(get git_token || echo none)"
GIT_AUTH=()
if [ -n "$TOKEN" ] && [ "$TOKEN" != "none" ]; then
  GIT_AUTH=(-c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
fi

echo "=== 4/6 Fetching the application code"
mkdir -p "$INSTALL_DIR"
if [ ! -d "$INSTALL_DIR/repo/.git" ]; then
  git "$${GIT_AUTH[@]}" clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
fi
COMPOSE_DIR="$INSTALL_DIR/repo/hrms-develop/infra/aws/compose"

echo "=== 5/6 Writing configuration (root-only)"
umask 077
cat > "$COMPOSE_DIR/.env" <<ENVEOF
PROJECT_NAME=$PROJECT
SITE_NAME=$DOMAIN
ADMIN_PASSWORD=$(get admin_password)
DB_ROOT_PASSWORD=$(get db_root_password)
GUNICORN_WORKERS=3
BACKUP_BUCKET=$BUCKET
AWS_REGION=$REGION
ENVEOF
chmod 600 "$COMPOSE_DIR/.env"
umask 022

cat > /etc/cron.d/medware-backup <<CRONEOF
# Daily backup at 02:00 UTC (05:00 in Nairobi)
0 2 * * * root $COMPOSE_DIR/backup.sh >> /var/log/medware-backup.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/medware-backup

echo "=== 6/6 Building and starting the stack (first build takes 20-40 minutes)"
cd "$COMPOSE_DIR"
docker compose up -d --build

echo "Bootstrap finished. Point DNS ($DOMAIN) at this server's Elastic IP so HTTPS can be issued."
