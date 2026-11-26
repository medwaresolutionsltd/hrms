#!bin/bash

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd frappe-bench
    exec bench start
else
    echo "Creating new bench..."
fi

export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

# GitHub can be flaky on some networks: retry network steps
retry() { for i in 1 2 3 4 5 6; do "$@" && return 0; echo "Attempt $i failed: $*; retrying in 15s"; sleep 15; done; return 1; }
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 60

retry_init() { rm -rf frappe-bench; bench init --skip-redis-config-generation --frappe-branch develop frappe-bench; }
retry retry_init || exit 1

cd frappe-bench

# Use containers instead of localhost
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove redis, watch from Procfile
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile
sed -i 's/bench serve  *--port 8000/bench serve --port 8000 --host 0.0.0.0/' ./Procfile

retry bench get-app --branch develop erpnext
# Use the local, customised Medware HRMS source (soft-linked so edits show up live).
# (bench get-app --soft-link fails on local paths, so link and install manually)
ln -sfn /workspace apps/hrms
uv pip install --quiet -e apps/hrms --python env/bin/python
grep -qx hrms sites/apps.txt || printf '\nhrms\n' >> sites/apps.txt

bench new-site medware.localhost \
--force \
--mariadb-root-password 123 \
--admin-password admin \
--no-mariadb-socket

bench --site medware.localhost install-app hrms
bench --site medware.localhost set-config developer_mode 1
bench --site medware.localhost enable-scheduler
bench --site medware.localhost clear-cache
bench use medware.localhost

bench start