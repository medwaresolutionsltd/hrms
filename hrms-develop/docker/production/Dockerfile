# Production image for Medware HR (Frappe + ERPNext + this repo as the `hrms` app).
#
# Build context is the repo's hrms-develop/ folder (see infra/aws/compose/docker-compose.yml). One container runs every
# Frappe process (nginx, gunicorn, socketio, scheduler, worker) behind a TLS-terminating proxy
# (Caddy), so a single host needs only one app container plus MariaDB and Redis.

FROM frappe/bench:latest

ARG FRAPPE_BRANCH=develop
ARG ERPNEXT_BRANCH=develop

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe

RUN bench init --skip-redis-config-generation --skip-assets --frappe-branch ${FRAPPE_BRANCH} frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch ${ERPNEXT_BRANCH} erpnext

# HRMS comes from this repository, not from GitHub, so what is deployed is exactly what is committed.
COPY --chown=frappe:frappe . apps/hrms
RUN uv pip install --quiet -e apps/hrms --python env/bin/python \
    && printf '\nhrms\n' >> sites/apps.txt

# Page-island builds resolve the app's JS dependencies from beside the app; share Frappe's.
RUN mkdir -p apps/hrms/node_modules/@framework \
    && ln -sfn /home/frappe/frappe-bench/apps/frappe/ui apps/hrms/node_modules/@framework/ui \
    && for p in /home/frappe/frappe-bench/apps/frappe/node_modules/*; do \
         [ -e "apps/hrms/node_modules/$(basename "$p")" ] || ln -s "$p" "apps/hrms/node_modules/$(basename "$p")"; \
       done

# Desk assets, then the Medware HR mobile app (PWA) and roster frontends.
RUN bench build
RUN cd apps/hrms && yarn install --network-timeout 600000 && yarn build

# `sites/` is replaced by the persistent disk at runtime, so keep the built assets aside.
# The entrypoint copies them back onto the disk on every start.
RUN mv sites /home/frappe/sites-image

COPY --chown=frappe:frappe docker/production/nginx.conf /home/frappe/nginx.conf
COPY --chown=frappe:frappe docker/production/Procfile /home/frappe/Procfile
COPY --chown=frappe:frappe docker/production/entrypoint.sh /home/frappe/entrypoint.sh
RUN chmod +x /home/frappe/entrypoint.sh

ENV PORT=10000
EXPOSE 10000
CMD ["/home/frappe/entrypoint.sh"]
