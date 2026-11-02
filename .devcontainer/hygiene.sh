#!/usr/bin/env bash
# Devcontainer writable-layer hygiene (igou-devenv#187), run from post-start.
# Everything under ~ and /tmp that is not a bind mount lands in the container's
# overlay, which shares the host root LV — nested podman images alone reached
# 17G-22G in three separate disk-pressure incidents. Each step is best-effort
# and never removes anything that cannot be rebuilt or re-pulled.
set -u

RETENTION_DAYS="${HYGIENE_RETENTION_DAYS:-7}"

# Nested podman: dangling layers now, tagged-but-unused images after the
# retention window. All images here come from a registry or a local build
# that the repo can reproduce; running containers and their images are kept.
if command -v podman >/dev/null 2>&1; then
    podman image prune -a -f --filter "until=$((RETENTION_DAYS * 24))h" >/dev/null 2>&1 \
        && echo "    podman: pruned images unused for ${RETENTION_DAYS}d" \
        || echo "    podman: prune skipped (not usable here)"
fi

# Package caches: rebuilt on demand.
command -v uv >/dev/null 2>&1 && uv cache prune -q >/dev/null 2>&1
command -v pip >/dev/null 2>&1 && pip cache purge >/dev/null 2>&1
echo "    caches: uv/pip pruned"
exit 0
