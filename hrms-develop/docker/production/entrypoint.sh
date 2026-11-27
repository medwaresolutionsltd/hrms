#!/bin/bash
# Production entrypoint for the single-container Medware HR deployment.
#
# Required environment (set in infra/aws/compose/.env, see docker-compose.yml):
#   SITE_NAME         public host name, e.g. hr.example.com (also the Frappe site name)
#   ADMIN_PASSWORD    Administrator password, used only when the site is first created
#   DB_HOST, DB_PORT, DB_ROOT_PASSWORD   MariaDB private service
#   REDIS_URL         redis://redis:6379
# Optional: GUNICORN_WORKERS (default 2), PORT (default 10000)

set -euo pipefail

: "${SITE_NAME:?SITE_NAME is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
: "${REDIS_URL:?REDIS_URL is required}"
DB_PORT="${DB_PORT:-3306}"
PORT="${PORT:-10000}"

BENCH=/home/frappe/frappe-bench
IMAGE_SITES=/home/frappe/sites-image
cd "$BENCH"

# 1. `sites/` is the persistent disk. Put this build's assets and app list on it every start,
#    so a new deploy always serves its own (freshly hashed) assets.
mkdir -p sites
rm -rf sites/assets
cp -a "$IMAGE_SITES/assets" sites/assets
cp -f "$IMAGE_SITES/apps.txt" sites/apps.txt
[ -f sites/common_site_config.json ] || echo '{}' > sites/common_site_config.json

# 2. Point Frappe at the private MariaDB and Redis (re-applied each start, so changes take effect).
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT" --parse
bench set-config -g redis_cache "$REDIS_URL"
bench set-config -g redis_queue "$REDIS_URL"
bench set-config -g redis_socketio "$REDIS_URL"
bench set-config -g webserver_port 8000 --parse
bench set-config -g socketio_port 9000 --parse
bench set-config -g default_site "$SITE_NAME"
bench set-config -g serve_default_site true --parse

# 3. Wait for the database to accept connections.
for i in $(seq 1 60); do
  if (echo > "/dev/tcp/$DB_HOST/$DB_PORT") 2>/dev/null; then break; fi
  echo "Waiting for MariaDB at $DB_HOST:$DB_PORT ($i/60)"
  sleep 5
done

# 4. First start creates the site; later starts apply any pending migrations.
if [ ! -f "sites/$SITE_NAME/site_config.json" ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required to create the site}"
  echo "Creating site $SITE_NAME"
  bench new-site "$SITE_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --mariadb-user-host-login-scope='%' \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext --install-app hrms \
    --set-default
else
  echo "Site $SITE_NAME exists, running migrations"
  bench --site "$SITE_NAME" migrate
fi

bench --site "$SITE_NAME" set-config host_name "https://$SITE_NAME"
bench --site "$SITE_NAME" enable-scheduler

# 5. Render the nginx config (only ${PORT} and ${SITE_NAME} are substituted) and run everything.
mkdir -p /tmp/nginx-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
sed -e "s/\${PORT}/$PORT/g" -e "s/\${SITE_NAME}/$SITE_NAME/g" /home/frappe/nginx.conf > /tmp/nginx.conf

# honcho stops every process if any one exits, so Docker (restart: unless-stopped) restarts the container cleanly.
exec honcho -f /home/frappe/Procfile -d "$BENCH" start
