#!/usr/bin/env bash
# Cache the prebuilt Docker images between CI runs so we don't re-download
# hundreds of MB every time. This does NOT build anything — it warms the local
# Docker daemon from a tarball cache, then `docker compose pull` only fetches
# what actually changed on the registry.
#
# Usage:
#   scripts/image-cache.sh key            -> print a cache key from the image list
#   scripts/image-cache.sh load <dir>     -> docker load every *.tar found in <dir>
#   scripts/image-cache.sh save <dir>     -> docker save each image into <dir>
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-}"
dir="${2:-.image-cache}"

NODE=(docker run --rm -v "$PWD":/w -w /w node:24-alpine node)
sanitize() { echo "$1" | tr '/:' '__'; }

images() { "${NODE[@]}" scripts/image-list.mjs; }

case "$cmd" in
  key)
    # Stable key over the sorted image list (versions+flavor+mode all fold in here).
    images | LC_ALL=C sort | sha256sum | awk '{print "imgcache-" $1}'
    ;;
  load)
    if [ -d "$dir" ]; then
      shopt -s nullglob
      for t in "$dir"/*.tar; do
        echo "docker load < $t"
        docker load -i "$t" || true
      done
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
