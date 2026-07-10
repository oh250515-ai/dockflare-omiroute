#!/usr/bin/env bash
# Runs ON the Docker host. Only requirement: Docker (with the compose plugin).
# Node is not required on the host — we run the JS helpers in a throwaway container.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config.json ] || { echo "config.json not found in $(pwd)" >&2; exit 1; }

NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)

MODE=$("${NODE[@]}" -e "process.stdout.write(((JSON.parse(require('fs').readFileSync('config.json','utf8')).access||{}).mode||'public').toLowerCase())")

if [ "$MODE" != "tailscale" ]; then
  "${NODE[@]}" scripts/cf-bootstrap.mjs
fi
"${NODE[@]}" scripts/render.mjs

# shellcheck disable=SC1091
source .deploy-plan

if [ "$MODE" != "tailscale" ]; then
  docker network inspect cloudflare-net >/dev/null 2>&1 || docker network create cloudflare-net
fi

# shellcheck disable=SC2086
COMPOSE=(docker compose $COMPOSE_FILES)

"${COMPOSE[@]}" pull
"${COMPOSE[@]}" up -d --remove-orphans

echo "Waiting for OmniRoute containers to report healthy..."
for _ in $(seq 1 60); do
  bad=0
  names=$(docker ps --filter "name=omniroute-" --format '{{.Names}}')
  [ -z "$names" ] && bad=1
  for c in $names; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
    [ "$st" = "healthy" ] || bad=1
  done
  if [ "$bad" = "0" ]; then echo "All OmniRoute containers healthy."; break; fi
  sleep 5
done

"${COMPOSE[@]}" ps
rm -f .cf-resolved.json
echo "Done (mode=$MODE). In public mode, DockFlare provisions the tunnel + DNS per hostname."
