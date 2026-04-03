#!/bin/bash
# Container entrypoint: configure git identity, sandbox config, and GitHub PAT auth.
# Writes to /tmp because the root filesystem is effectively read-only.

# Merge baked Cursor sandbox config into workspace .cursor/sandbox.json.
# When a workspace sandbox.json already exists, merge network allow lists and paths.
# When none exists, copy the baked config as-is.
BAKED_SANDBOX="/etc/cursor/sandbox.json"
MERGE_SCRIPT="/usr/local/lib/cursor-container/merge-sandbox.py"
if [ -f "$BAKED_SANDBOX" ]; then
    WORKSPACE_DIR="$(pwd)"
    TARGET_DIR="${WORKSPACE_DIR}/.cursor"
    TARGET="${TARGET_DIR}/sandbox.json"
    mkdir -p "$TARGET_DIR" 2>/dev/null || true
    if [ -f "$TARGET" ]; then
        python3 "$MERGE_SCRIPT" "$BAKED_SANDBOX" "$TARGET" 2>/dev/null || cp "$BAKED_SANDBOX" "$TARGET"
    else
        cp "$BAKED_SANDBOX" "$TARGET"
    fi
fi

# Git config in /tmp (system paths are not user-writable)
export GIT_CONFIG_GLOBAL="/tmp/.gitconfig"

git config --global user.name "cursor-agent[bot]"
git config --global user.email "noreply@github.com"

# GitHub PAT auth (GITHUB_TOKEN passed via -e flag from op inject)
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > /tmp/.git-credentials
    chmod 600 /tmp/.git-credentials
    git config --global credential.helper "store --file=/tmp/.git-credentials"
    echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null || true
fi

exec "$@"
