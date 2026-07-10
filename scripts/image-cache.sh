#!/usr/bin/env bash
# Cache the prebuilt Docker images between CI runs so we don't re-download
# hundreds of MB every time. This does NOT build anything — it warms the local
# Docker daemon from a tarball cache, then the parallel prepull only fetches
# what actually changed on the registry.
#
# Usage:
#   scripts/image-cache.sh key            -> print a cache key from the image list
#   scripts/image-cache.sh load <dir>     -> docker load every *.tar found in <dir>
#   scripts/image-cache.sh save <dir>     -> docker save each image into <dir>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

cmd="${1:-}"
dir="${2:-.image-cache}"

sanitize() { echo "$1" | tr '/:' '__'; }
images() { "${NODE[@]}" scripts/image-list.mjs; }

case "$cmd" in
  key)
    images | LC_ALL=C sort | sha256sum | awk '{print "imgcache-" $1}'
    ;;
  load)
    if [ -d "$dir" ]; then
      shopt -s nullglob
      # Load tarballs in parallel too.
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
