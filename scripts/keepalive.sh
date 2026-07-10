#!/usr/bin/env bash
# TEST-ONLY keep-alive. Deploys on THIS runner's local Docker, prints detailed
# step-by-step diagnostics, then probes the public URLs until reachable and holds
# the CI job open so you can test.
#
# WHY THIS IS TEMPORARY: GitHub-hosted jobs are capped at ~6h and the machine is
# destroyed when the job ends — containers + tunnel go with it. Great for kicking
# the tires, not for a real deployment (use a self-hosted runner or server.* for that).
set -uo pipefail
cd "$(dirname "$0")/.."
chmod +x scripts/*.sh

# 1) Deploy locally on the runner (no server block -> ci-deploy.sh runs deploy.sh here).
#    Verbose: show every command as it runs so the CI log pinpoints any failure.
echo "::group::Deploy (verbose)"
bash -x ./scripts/ci-deploy.sh 2>&1 || echo "ci-deploy.sh exited non-zero (continuing to diagnostics)"
echo "::endgroup::"

# 2) Immediate diagnostics snapshot right after deploy.
echo "::group::Diagnostics (post-deploy snapshot)"
./scripts/diagnose.sh || true
echo "::endgroup::"

# 3) Work out which URLs to probe from the config.
NODE=(node); command -v node >/dev/null 2>&1 || NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)
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

DEADLINE=$(( $(date +%s) + ${KEEPALIVE_MINUTES:-330}*60 ))
declare -A SEEN
announced_all=0
loops=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
 allok=1
 for u in "${URLS[@]}"; do
 code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || echo 000)
 case "$code" in
 200|301|302|307|308)
 if [ "${SEEN[$u]:-}" != "1" ]; then echo "[$(date -u +%H:%M:%S)] REACHABLE $u ($code)"; SEEN[$u]=1; fi ;;
 *)
 allok=0
 echo "[$(date -u +%H:%M:%S)] waiting $u -> $code" ;;
 esac
 done
 if [ "$allok" = "1" ] && [ "${#URLS[@]}" -gt 0 ] && [ "$announced_all" = "0" ]; then
 echo "=================================================================="
 echo " ALL VERSIONS REACHABLE FROM THE INTERNET. Holding open for testing."
 echo "=================================================================="
 announced_all=1
 fi
 # Every ~2 min while not-yet-all-reachable, dump a fresh diagnostics snapshot
 # so the CI log shows how the tunnel/DNS/containers are progressing.
 if [ "$allok" != "1" ]; then
 loops=$((loops+1))
 if [ $((loops % 4)) -eq 0 ]; then
 echo "::group::Diagnostics (t+$((loops*30))s)"
 ./scripts/diagnose.sh || true
 echo "::endgroup::"
 fi
 fi
 sleep 30
done
echo "Keep-alive window elapsed. Job ending; the ephemeral host + tunnel tear down now."
