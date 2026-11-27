#!/bin/bash
# Pull the latest code and rebuild/restart the stack. Run on the server:
#   sudo /opt/medware/repo/hrms-develop/infra/aws/compose/deploy.sh [branch]
# Takes a backup first, so a bad update can be rolled back from a known-good copy.
set -euo pipefail
export PATH="$PATH:/snap/bin"

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$COMPOSE_DIR/../../../.." && pwd)"
set -a; . "$COMPOSE_DIR/.env"; set +a
BRANCH="${1:-main}"

echo "Taking a pre-deploy backup"
"$COMPOSE_DIR/backup.sh"

# The GitHub token (only needed for a private repository) stays in SSM, never on disk.
TOKEN="$(aws ssm get-parameter --region "$AWS_REGION" --name "/${PROJECT_NAME:-medware-hr}/git_token" \
  --with-decryption --query Parameter.Value --output text 2>/dev/null || echo none)"
GIT_AUTH=()
if [ -n "$TOKEN" ] && [ "$TOKEN" != "none" ]; then
  GIT_AUTH=(-c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
fi

cd "$REPO_DIR"
git "${GIT_AUTH[@]}" fetch origin "$BRANCH"
git checkout "$BRANCH"
git "${GIT_AUTH[@]}" pull --ff-only origin "$BRANCH"

cd "$COMPOSE_DIR"
docker compose up -d --build
docker image prune -f
echo "Deployed $(git -C "$REPO_DIR" rev-parse --short HEAD). The app runs migrations on start; watch with:"
echo "  docker compose -f $COMPOSE_DIR/docker-compose.yml logs -f app"
