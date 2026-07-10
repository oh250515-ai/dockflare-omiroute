#!/usr/bin/env bash
# Shared entrypoint for GitHub Actions AND Azure Pipelines.
# Decides where to deploy based on whether config.json has a "server" block:
#   - server.host present  -> deploy to that remote host over SSH (persistent host).
#   - server absent        -> deploy on THIS runner's local Docker.
#
# keep-alive (config.deploy.keepAlive = true):
#   Only meaningful in local mode. After bringing services up, the job BLOCKS and
#   monitors health so the OmniRoute containers + Cloudflare tunnel stay alive for
#   as long as the runner lives. On an ephemeral hosted runner this lasts until the
#   job timeout (GitHub: hard cap ~6h). Good for a live test; NOT durable hosting.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config.json ] || { echo "config.json not found (expected the DEPLOY_CONFIG_JSON secret written here)" >&2; exit 1; }

NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)

read -r HAS_SERVER HOST SSH_USER SSH_PORT RPATH KEEPALIVE KEEPMIN < <("${NODE[@]}" -e '
  const c=JSON.parse(require("fs").readFileSync("config.json","utf8"));
  const s=c.server||{}, d=c.deploy||{};
  process.stdout.write([
    s.host?"yes":"no", s.host||"-", s.user||"root", s.port||22, s.path||"/opt/dockflare-omniroute",
    d.keepAlive?"yes":"no", d.keepAliveMinutes||330
  ].join(" "));
')

chmod +x scripts/*.sh || true

if [ "$HAS_SERVER" = "no" ]; then
  echo "No server block -> deploying on this runner's local Docker."
  ./scripts/deploy.sh
  if [ "$KEEPALIVE" = "yes" ]; then
    echo "::notice::keep-alive on. Holding the job for up to ${KEEPMIN} min so the tunnel stays up."
    END=$(( $(date +%s) + KEEPMIN * 60 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      ts=$(date -u +%H:%M:%S)
      for c in $(docker ps --filter "name=omniroute-" --format '{{.Names}}'); do
        st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$c" 2>/dev/null || echo '?')
        echo "[$ts] $c: $st"
      done
      sleep 120
    done
    echo "keep-alive window elapsed; job will end and the runner (and tunnel) will be torn down."
  fi
  exit 0
fi

echo "server.host set -> deploying to ${SSH_USER}@${HOST}:${SSH_PORT} (${RPATH}) over SSH."

"${NODE[@]}" -e '
  const fs=require("fs");
  const s=JSON.parse(fs.readFileSync("config.json","utf8")).server||{};
  if(!s.sshKey){ console.error("server.sshKey is required for remote deploy"); process.exit(1); }
  fs.writeFileSync("deploy_key", s.sshKey.endsWith("\n")?s.sshKey:s.sshKey+"\n", {mode:0o600});
'

mkdir -p ~/.ssh
mv deploy_key ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy
ssh-keyscan -p "$SSH_PORT" -H "$HOST" >> ~/.ssh/known_hosts 2>/dev/null || true

rsync -az --delete \
  -e "ssh -i ~/.ssh/id_deploy -p ${SSH_PORT}" \
  --exclude '.git' \
  ./ "${SSH_USER}@${HOST}:${RPATH}/"

ssh -i ~/.ssh/id_deploy -p "$SSH_PORT" "${SSH_USER}@${HOST}" \
  "cd '${RPATH}' && chmod +x scripts/*.sh && ./scripts/deploy.sh"

rm -f ~/.ssh/id_deploy
