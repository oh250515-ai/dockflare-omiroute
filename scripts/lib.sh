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
