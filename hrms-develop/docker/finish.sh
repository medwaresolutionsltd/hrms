#!/bin/bash
# Resume setup inside an existing bench (after the init.sh bench-build succeeded)
set -x
cd /home/frappe/frappe-bench
ln -sfn /workspace apps/hrms
uv pip install --quiet -e apps/hrms --python env/bin/python || exit 1
grep -qx hrms sites/apps.txt || printf '\nhrms\n' >> sites/apps.txt
# Frappe's page-island build resolves HRMS by its real path (/workspace), outside the bench,
# so it cannot find the bench's JS dependencies. Link them into the repo's (gitignored) node_modules.
mkdir -p /workspace/node_modules/@framework
ln -sfn /home/frappe/frappe-bench/apps/frappe/ui /workspace/node_modules/@framework/ui
for p in /home/frappe/frappe-bench/apps/frappe/node_modules/* /home/frappe/frappe-bench/apps/frappe/node_modules/.bin; do
    [ -e "/workspace/node_modules/$(basename "$p")" ] || ln -s "$p" "/workspace/node_modules/$(basename "$p")"
done
# Site was already created by the previous run; only create it if missing
[ -f sites/medware.localhost/site_config.json ] || bench new-site medware.localhost --force --mariadb-root-password 123 --admin-password admin --no-mariadb-socket || exit 1
bench --site medware.localhost list-apps | grep -q "^erpnext" || bench --site medware.localhost install-app erpnext || exit 1
bench --site medware.localhost install-app hrms || exit 1
bench --site medware.localhost set-config developer_mode 1
bench --site medware.localhost enable-scheduler
bench --site medware.localhost clear-cache
bench use medware.localhost
echo FINISH-DONE
