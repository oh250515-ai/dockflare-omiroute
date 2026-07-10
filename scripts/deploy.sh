#!/usr/bin/env bash
# Runs ON the Docker host. Only requirement: Docker (with the compose plugin).
# Flow (deliberately tiny): prepare .env -> seed DockFlare -> compose up -> wait.
# Services are defined in the committed docker-compose.*.yml — this script never
# generates compose.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

[ -f config.json ] || { echo "config.json not found in $(pwd)" >&2; exit 1; }

# 1. Translate the single secret into .env (+ .df-seed.json + .deploy-plan).
"${NODE[@]}" scripts/prepare-env.mjs

# shellcheck disable=SC1091
source .deploy-plan   # -> MODE, COMPOSE_FILES

# 2. Shared external network (public mode).
if [ "$MODE" != "tailscale" ]; then
  docker network inspect cloudflare-net >/dev/null 2>&1 || docker network create cloudflare-net
fi

# 3. Faster pulls: Docker Hub login (if creds) + parallel prepull of the exact
#    images the selected compose files reference.
docker_login
echo "Pre-pulling images in parallel..."
# shellcheck disable=SC2086
docker compose $COMPOSE_FILES config --images 2>/dev/null | sort -u | prepull_parallel

# 4. Seed DockFlare headlessly so it boots into Operational Mode (public mode).
if [ "$MODE" != "tailscale" ]; then
  echo "Seeding DockFlare config (headless, no wizard)..."
  docker run --rm -v dockflare_data:/app/data -v "$PWD":/work -w /work \
    --entrypoint python alplat/dockflare:stable scripts/seed-dockflare.py
  cat .df-admin.txt 2>/dev/null || true
fi

# 5. Bring it up from the committed compose files.
# shellcheck disable=SC2086
COMPOSE=(docker compose $COMPOSE_FILES)
"${COMPOSE[@]}" up -d --remove-orphans

# 6. Readiness: OmniRoute's own healthcheck is a known false-negative in some
#    network setups (#3151); accept 'healthy' OR actually-serving-HTTP on 20128.
echo "Waiting for OmniRoute to be ready (health OR serving HTTP on :20128)..."
for _ in $(seq 1 60); do
  bad=0
  names=$(docker ps --filter "name=omniroute-" --format '{{.Names}}')
  [ -z "$names" ] && bad=1
  for c in $names; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
    if [ "$st" = "healthy" ]; then continue; fi
    code=$(docker exec "$c" node -e 'fetch("http://127.0.0.1:20128/").then(r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log(0);process.exit(0)})' 2>/dev/null || echo 0)
    case "$code" in 200|301|302|307|308|401) : ;; *) bad=1 ;; esac
  done
  if [ "$bad" = "0" ]; then echo "OmniRoute is serving."; break; fi
  sleep 5
done

"${COMPOSE[@]}" ps
rm -f .df-seed.json
echo "Done (mode=$MODE). In public mode, DockFlare provisions the tunnel + DNS per hostname."
