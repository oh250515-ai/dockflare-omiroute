#!/usr/bin/env bash
# Shared helpers. Source this: `source "$(dirname "$0")/lib.sh"`.

# NODE runner: use the host's node when present (CI runners ship Node) instead of
# spinning up a node:24-alpine container for every tiny JS call — those repeated
# container starts + the ~50MB image pull were a big chunk of the slowness.
if command -v node >/dev/null 2>&1; then
  NODE=(node)
else
  NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)
fi
export NODE

# Authenticate to Docker Hub if creds are present in config.json (dockerhub block).
# Anonymous pulls are rate-limited (and throttled/slow when the shared runner IP is
# hot); an authenticated pull gets a much higher limit and is noticeably faster.
# Kept inside the single DEPLOY_CONFIG_JSON secret so there is still ONE secret.
docker_login() {
  [ -f config.json ] || return 0
  local u t
  u=$("${NODE[@]}" -e "process.stdout.write(((JSON.parse(require('fs').readFileSync('config.json','utf8')).dockerhub||{}).username||''))" 2>/dev/null || echo "")
  t=$("${NODE[@]}" -e "process.stdout.write(((JSON.parse(require('fs').readFileSync('config.json','utf8')).dockerhub||{}).token||''))" 2>/dev/null || echo "")
  if [ -n "$u" ] && [ -n "$t" ]; then
    echo "Logging in to Docker Hub as $u (higher pull rate limit)..."
    printf '%s' "$t" | docker login -u "$u" --password-stdin >/dev/null 2>&1 \
      && echo "Docker Hub login OK." \
      || echo "Docker Hub login failed (continuing anonymously)."
  else
    echo "No dockerhub creds in config — pulling anonymously."
  fi
}

# Pull a list of images (stdin, one per line) in parallel. Much faster than the
# sequential pulls docker compose does, especially for the big OmniRoute images.
prepull_parallel() {
  local max="${PREPULL_CONCURRENCY:-6}"
  local pids=() img
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    docker pull -q "$img" &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$max" ]; then wait "${pids[0]}" 2>/dev/null || true; pids=("${pids[@]:1}"); fi
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
}
