#!/usr/bin/env bash
# Devcontainer writable-layer hygiene (igou-devenv#187), run from post-start.
# Everything under ~ and /tmp that is not a bind mount lands in the container's
# overlay, which shares the host root LV — nested podman images alone reached
# 17G-22G in three separate disk-pressure incidents. Each step is best-effort
# and never removes anything that cannot be rebuilt or re-pulled.
set -u

RETENTION_DAYS="${HYGIENE_RETENTION_DAYS:-7}"
CLAUDE_KEEP_VERSIONS="${HYGIENE_CLAUDE_KEEP_VERSIONS:-2}"

# Nested podman: dangling layers now, tagged-but-unused images after the
# retention window. All images here come from a registry or a local build
# that the repo can reproduce; running containers and their images are kept.
if command -v podman >/dev/null 2>&1; then
    podman image prune -a -f --filter "until=$((RETENTION_DAYS * 24))h" >/dev/null 2>&1 \
        && echo "    podman: pruned images unused for ${RETENTION_DAYS}d" \
        || echo "    podman: prune skipped (not usable here)"
fi

# Claude CLI auto-updates keep every version (~280M each): keep the newest N.
versions="$HOME/.local/share/claude/versions"
if [ -d "$versions" ]; then
    find "$versions" -mindepth 1 -maxdepth 1 -printf '%T@ %p\n' | sort -rn \
        | tail -n +"$((CLAUDE_KEEP_VERSIONS + 1))" | cut -d' ' -f2- \
        | while read -r v; do rm -rf "$v"; done
    echo "    claude: kept newest ${CLAUDE_KEEP_VERSIONS} CLI versions"
fi

# Agent session scratchpads (repo clones, venvs) from sessions long finished.
scratch="/tmp/claude-$(id -u)"
if [ -d "$scratch" ]; then
    find "$scratch" -mindepth 2 -maxdepth 2 -type d -mtime "+${RETENTION_DAYS}" \
        -exec rm -rf {} + 2>/dev/null
    echo "    scratchpads: removed session dirs older than ${RETENTION_DAYS}d"
fi

# Package caches: rebuilt on demand.
command -v uv >/dev/null 2>&1 && uv cache prune -q >/dev/null 2>&1
command -v pip >/dev/null 2>&1 && pip cache purge >/dev/null 2>&1
echo "    caches: uv/pip pruned"
exit 0
