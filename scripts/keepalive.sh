#!/usr/bin/env bash
# TEST-ONLY keep-alive. Deploys on THIS runner's local Docker, then probes the
# public URLs until reachable and holds the CI job open so you can test.
#
# WHY THIS IS TEMPORARY: GitHub-hosted jobs are capped at ~6h and the machine is
# destroyed when the job ends — containers + tunnel go with it. Great for kicking
# the tires, not for a real deployment (use a self-hosted runner or server.* for that).
set -uo pipefail
cd "$(dirname "$0")/.."

# 1) Deploy locally on the runner (no server block -> ci-deploy.sh runs deploy.sh here).
chmod +x scripts/*.sh
./scripts/ci-deploy.sh

# 2) Work out which URLs to probe from the config.
NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)
mapfile -t URLS < <("${NODE[@]}" -e '
  const fs=require("fs");
  const c=JSON.parse(fs.readFileSync("config.json","utf8"));
  const omni=c.omniroute||{}; const acc=c.access||{};
  const mode=((acc.mode)||"public").toLowerCase();
  const versions=(omni.versions&&omni.versions.length)?omni.versions:["latest"];
  const slug=v=>v==="latest"?"latest":"v"+String(v).replace(/[^a-zA-Z0-9]+/g,"-").replace(/^-+|-+$/g,"");
  if(mode!=="tailscale"){
    const base=(c.cloudflare||{}).domain;
    versions.forEach(v=>console.log("https://"+slug(v)+"."+base));
  }
')

if [ "${#URLS[@]}" -eq 0 ]; then
  echo "No public URLs to probe (tailscale/private mode). Holding job open anyway."
fi

echo "::group::Probing external URLs (Cloudflare tunnel + DNS can take a few minutes)"
DEADLINE=$(( $(date +%s) + ${KEEPALIVE_MINUTES:-330}*60 ))
declare -A SEEN
announced_all=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  allok=1
  for u in "${URLS[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || echo 000)
    case "$code" in
      200|301|302|307|308)
        if [ "${SEEN[$u]:-}" != "1" ]; then echo "[$(date -u +%H:%M:%S)] REACHABLE  $u  ($code)"; SEEN[$u]=1; fi ;;
      *)
        allok=0
        echo "[$(date -u +%H:%M:%S)] waiting    $u  -> $code" ;;
    esac
  done
  if [ "$allok" = "1" ] && [ "${#URLS[@]}" -gt 0 ] && [ "$announced_all" = "0" ]; then
    echo "=================================================================="
    echo " ALL VERSIONS REACHABLE FROM THE INTERNET. Holding open for testing."
    echo "=================================================================="
    announced_all=1
  fi
  sleep 30
done
echo "::endgroup::"
echo "Keep-alive window elapsed. Job ending; the ephemeral host + tunnel tear down now."
