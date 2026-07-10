#!/usr/bin/env bash
# Runs on the Docker host. Only requirement: Docker (with compose plugin).
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f config.json ]; then
  echo "config.json not found in $(pwd)" >&2
  exit 1
fi

# Render .env + docker-compose.omniroute.yml using a throwaway Node container,
# so the host itself needs no Node install.
docker run --rm -v "$PWD":/w -w /w node:24-alpine node scripts/render.mjs

# Shared external network used by DockFlare + OmniRoute.
docker network inspect cloudflare-net >/dev/null 2>&1 || docker network create cloudflare-net

COMPOSE="docker compose -f docker-compose.dockflare.yml -f docker-compose.omniroute.yml"

$COMPOSE pull
$COMPOSE up -d --remove-orphans

echo "Waiting for OmniRoute containers to report healthy..."
for _ in $(seq 1 60); do
  bad=0
  names=$(docker ps --filter "name=omniroute-" --format '{{.Names}}')
  [ -z "$names" ] && bad=1
  for c in $names; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
    [ "$st" = "healthy" ] || bad=1
  done
  if [ "$bad" = "0" ]; then
    echo "All OmniRoute containers healthy."
    break
  fi
  sleep 5
done

$COMPOSE ps
echo "Done. DockFlare is provisioning tunnel + DNS for each OmniRoute hostname."
