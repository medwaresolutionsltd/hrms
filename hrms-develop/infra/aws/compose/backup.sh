#!/bin/bash
# Daily backup: Frappe database + files -> /data/sites/<site>/private/backups -> S3.
# Installed in /etc/cron.d by the bootstrap script. Safe to run by hand:
#   sudo /opt/medware/repo/hrms-develop/infra/aws/compose/backup.sh
set -euo pipefail
export PATH="$PATH:/snap/bin"

cd "$(dirname "$0")"
set -a; . ./.env; set +a

BACKUP_DIR="/data/sites/${SITE_NAME}/private/backups"

echo "[$(date -u +%FT%TZ)] creating backup for ${SITE_NAME}"
docker compose exec -T app bench --site "${SITE_NAME}" backup --with-files

echo "[$(date -u +%FT%TZ)] uploading to s3://${BACKUP_BUCKET}/frappe/${SITE_NAME}/"
aws s3 sync "${BACKUP_DIR}" "s3://${BACKUP_BUCKET}/frappe/${SITE_NAME}/" \
  --region "${AWS_REGION}" --only-show-errors

# Keep two weeks locally; S3 holds the long-term copies (retention set by the bucket lifecycle).
find "${BACKUP_DIR}" -type f -mtime +14 -delete

echo "[$(date -u +%FT%TZ)] backup complete"
