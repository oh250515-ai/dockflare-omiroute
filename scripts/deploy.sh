#!/usr/bin/env bash
# Runs ON the Docker host. Only requirement: Docker (with the compose plugin).
# Uses host Node when available; otherwise falls back to a node container.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

[ -f config.json ] || { echo "config.json not found in $(pwd)" >&2; exit 1; }

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

# Authenticate to Docker Hub (if creds in config) for a higher/faster pull rate,
# then pull every image up front in parallel. This is the big speedup vs. compose's
# sequential anonymous pulls — the OmniRoute images are ~400MB each.
docker_login
echo "Pre-pulling images in parallel..."
"${NODE[@]}" scripts/image-list.mjs | prepull_parallel

# --- Seed DockFlare headlessly (public mode) -------------------------------
# Without this, DockFlare sits in Pre-Flight Mode waiting for the web wizard and
# never creates the tunnel/DNS. We write its encrypted config using DockFlare's
# OWN image so the crypto/hash libs match exactly.
if [ "$MODE" != "tailscale" ]; then
 "${NODE[@]}" -e '
 const fs=require("fs"), crypto=require("crypto");
 const r=JSON.parse(fs.readFileSync(".cf-resolved.json","utf8"));
 const c=JSON.parse(fs.readFileSync("config.json","utf8"));
 const d=c.dockflare||{};
 const pw=d.password||crypto.randomBytes(18).toString("base64url");
 const seed={
 cf_api_token:r.apiToken, cf_account_id:r.accountId, cf_zone_id:r.zoneId||null,
 tunnel_name:r.tunnelName||"dockflare-omniroute",
 username:d.username||"admin", password:pw, master_api_key:d.masterApiKey||null,
 };
 fs.writeFileSync(".df-seed.json", JSON.stringify(seed));
 fs.writeFileSync(".df-admin.txt", "DockFlare admin login — user: "+seed.username+" password: "+pw+"\n");
 '
 echo "Seeding DockFlare config (headless, no wizard)..."
 docker run --rm -v dockflare_data:/app/data -v "$PWD":/work -w /work \
 --entrypoint python alplat/dockflare:stable scripts/seed-dockflare.py
 cat .df-admin.txt 2>/dev/null || true
 rm -f .df-seed.json
fi

# shellcheck disable=SC2086
COMPOSE=(docker compose $COMPOSE_FILES)

"${COMPOSE[@]}" up -d --remove-orphans

# --- Readiness wait --------------------------------------------------------
# NOTE: OmniRoute's built-in Docker healthcheck is a KNOWN false-negative in
# some network setups (upstream #3151 / #296): the app serves fine on :20128 but
# the container reports (unhealthy). So we DON'T block only on Docker health — we
# accept a container that is either 'healthy' OR actually serving HTTP on 20128.
echo "Waiting for OmniRoute to be ready (health OR serving HTTP on :20128)..."
for _ in $(seq 1 60); do
 bad=0
 names=$(docker ps --filter "name=omniroute-" --format '{{.Names}}')
 [ -z "$names" ] && bad=1
 for c in $names; do
 st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
 if [ "$st" = "healthy" ]; then continue; fi
 # Fallback: does the app actually answer inside the container?
 code=$(docker exec "$c" node -e 'fetch("http://127.0.0.1:20128/").then(r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log(0);process.exit(0)})' 2>/dev/null || echo 0)
 case "$code" in 200|301|302|307|308|401) : ;; *) bad=1 ;; esac
 done
 if [ "$bad" = "0" ]; then echo "OmniRoute is serving."; break; fi
 sleep 5
done

"${COMPOSE[@]}" ps
rm -f .cf-resolved.json
echo "Done (mode=$MODE). In public mode, DockFlare provisions the tunnel + DNS per hostname."
echo "NOTE: a container marked (unhealthy) but serving HTTP is the known OmniRoute healthcheck quirk, not an outage."
