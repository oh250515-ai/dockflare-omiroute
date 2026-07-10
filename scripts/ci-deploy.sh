#!/usr/bin/env bash
# Shared entrypoint for GitHub Actions AND Azure Pipelines.
# Decides where to deploy based on whether config.json has a "server" block:
#   - server.host present  -> deploy to that remote host over SSH (use with GitHub/Azure HOSTED runners,
#                             which are ephemeral and cannot host a long-running service themselves).
#   - server absent        -> deploy on THIS runner's local Docker (use with a SELF-HOSTED / persistent
#                             runner — the runner's own machine is the Docker host, no SSH needed).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config.json ] || { echo "config.json not found (expected the DEPLOY_CONFIG_JSON secret written here)" >&2; exit 1; }

NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)

read -r HAS_SERVER HOST SSH_USER SSH_PORT RPATH < <("${NODE[@]}" -e '
  const s=(JSON.parse(require("fs").readFileSync("config.json","utf8")).server)||{};
  process.stdout.write([s.host?"yes":"no", s.host||"-", s.user||"root", s.port||22, s.path||"/opt/dockflare-omniroute"].join(" "));
')

chmod +x scripts/*.sh || true

if [ "$HAS_SERVER" = "no" ]; then
  echo "No server block -> deploying on this runner's local Docker (self-hosted/persistent runner)."
  exec ./scripts/deploy.sh
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
