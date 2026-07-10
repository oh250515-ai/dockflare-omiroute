#!/usr/bin/env bash
# Step-by-step diagnostics. Prints exactly where the stack is stuck: container
# states, DockFlare's own logs (tunnel creation, CF API errors), the managed
# cloudflared connector logs, each OmniRoute health, and live DNS resolution.
# Safe to run repeatedly. Never prints secrets (we grep DockFlare's log, which
# already redacts tokens).
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true

SECT() { echo; echo "===== $* ====="; }

SECT "1. All containers (name / image / status)"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true

SECT "2. DockFlare config seeded? (encrypted config present in volume)"
docker run --rm -v dockflare_data:/d alpine:3.20 sh -c \
  'ls -l /d/dockflare_config.dat /d/dockflare.key 2>&1; echo "---"; cat /d/state.json 2>/dev/null | head -c 800 || echo "(no state.json yet)"' || true

SECT "3. DockFlare admin login (generated headlessly)"
docker run --rm -v dockflare_data:/d alpine:3.20 sh -c 'cat /d/admin-credentials.txt 2>/dev/null || echo "(none)"' || true

SECT "4. DockFlare logs (last 120 lines) — tunnel init, CF API, reconcile"
docker logs --tail 120 dockflare 2>&1 || echo "(dockflare container not found)"

SECT "5. DockFlare health/overview API"
docker exec dockflare sh -c 'wget -qO- http://localhost:5000/ping; echo; wget -qO- http://localhost:5000/api/v2/overview 2>/dev/null | head -c 1200' 2>/dev/null \
  || curl -s --max-time 8 http://localhost:5000/ping || echo "(UI not responding yet)"

SECT "6. Managed cloudflared connector (container + logs)"
cf=$(docker ps -a --filter 'name=cloudflared' --format '{{.Names}}' | head -n1)
if [ -n "$cf" ]; then
  echo "connector: $cf"
  docker logs --tail 60 "$cf" 2>&1 || true
else
  echo "(no cloudflared connector yet — DockFlare starts it only AFTER the tunnel is created)"
fi

SECT "7. OmniRoute containers (state + health + last logs)"
for c in $(docker ps -a --filter 'name=omniroute-' --format '{{.Names}}'); do
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null)
  echo "--- $c : $st ---"
  docker logs --tail 25 "$c" 2>&1 | tail -n 25 || true
done

SECT "8. Live DNS resolution (has DockFlare created the CNAMEs yet?)"
NODE=(node); command -v node >/dev/null 2>&1 || NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)
mapfile -t HOSTS < <("${NODE[@]}" -e '
  const fs=require("fs");
  try{
    const c=JSON.parse(fs.readFileSync("config.json","utf8"));
    const base=(c.cloudflare||{}).domain; const o=c.omniroute||{};
    const vs=(o.versions&&o.versions.length)?o.versions:["latest"];
    const slug=v=>v==="latest"?"latest":"v"+String(v).replace(/[^a-zA-Z0-9]+/g,"-").replace(/^-+|-+$/g,"");
    if(base) vs.forEach(v=>console.log(slug(v)+"."+base));
  }catch(e){}
' 2>/dev/null)
for h in "${HOSTS[@]}"; do
  ans=$(curl -s --max-time 8 "https://dns.google/resolve?name=${h}&type=CNAME" || echo '{}')
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${h}" || echo 000)
  echo "$h -> dns:$(echo "$ans" | grep -o '\"Status\":[0-9]*') http:$code"
done

SECT "9. cloudflare-net membership"
docker network inspect cloudflare-net --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "(network missing)"

echo; echo "===== diagnostics end ====="
