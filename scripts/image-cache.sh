#!/usr/bin/env bash
# Cache the prebuilt Docker images between CI runs so we don't re-download
# hundreds of MB every time. This does NOT build anything.
#
# Image list = literal `image:` lines from the committed compose files + the
# cloudflared image DockFlare pulls at runtime. No dependency on config.json,
# so it works even before .env exists (e.g. for the cache key step).
#
# Usage:
#   scripts/image-cache.sh key            -> print a cache key from the image list
#   scripts/image-cache.sh load <dir>     -> docker load every *.tar found in <dir>
#   scripts/image-cache.sh save <dir>     -> docker save each image into <dir>
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-}"
dir="${2:-.image-cache}"
sanitize() { echo "$1" | tr '/:' '__'; }

images() {
  {
    grep -hoE '^[[:space:]]*image:[[:space:]]*\S+' docker-compose*.yml 2>/dev/null | awk '{print $2}'
    echo 'cloudflare/cloudflared:latest'   # DockFlare starts this itself
  } | LC_ALL=C sort -u
}

case "$cmd" in
  key)
    images | sha256sum | awk '{print "imgcache-" $1}'
    ;;
  load)
    if [ -d "$dir" ]; then
      shopt -s nullglob
      pids=()
      for t in "$dir"/*.tar; do
        echo "docker load < $t"
        docker load -i "$t" >/dev/null 2>&1 &
        pids+=("$!")
      done
      for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    else
      echo "No cache dir ($dir) yet — cold start."
    fi
    ;;
  save)
    mkdir -p "$dir"
    while IFS= read -r img; do
      [ -z "$img" ] && continue
      out="$dir/$(sanitize "$img").tar"
      if docker image inspect "$img" >/dev/null 2>&1; then
        echo "docker save $img -> $out"
        docker save "$img" -o "$out"
      fi
    done < <(images)
    ;;
  *)
    echo "usage: $0 {key|load <dir>|save <dir>}" >&2
    exit 1
    ;;
esac
