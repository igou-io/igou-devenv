#!/bin/bash
# Container entrypoint: configure git identity, sandbox config, and GitHub PAT auth.
# Writes to /tmp because the root filesystem is effectively read-only.

# Merge baked Cursor sandbox config into workspace .cursor/sandbox.json.
# When a workspace sandbox.json already exists, merge network allow lists and paths.
# When none exists, copy the baked config as-is.
BAKED_SANDBOX="/etc/cursor/sandbox.json"
if [ -f "$BAKED_SANDBOX" ]; then
    WORKSPACE_DIR="$(pwd)"
    TARGET_DIR="${WORKSPACE_DIR}/.cursor"
    TARGET="${TARGET_DIR}/sandbox.json"
    mkdir -p "$TARGET_DIR" 2>/dev/null || true
    if [ -f "$TARGET" ]; then
        python3 -c "
import json
with open('$TARGET') as f: user = json.load(f)
with open('$BAKED_SANDBOX') as f: baked = json.load(f)
for key in ('additionalReadwritePaths', 'additionalReadonlyPaths'):
    merged = list(set(user.get(key, []) + baked.get(key, [])))
    if merged:
        user[key] = sorted(merged)
bp = baked.get('networkPolicy', {})
up = user.setdefault('networkPolicy', {})
if bp.get('default') == 'deny' or up.get('default') == 'deny':
    up['default'] = 'deny'
up['allow'] = sorted(set(up.get('allow', []) + bp.get('allow', [])))
up['deny'] = sorted(set(up.get('deny', []) + bp.get('deny', [])))
for key in ('disableTmpWrite',):
    if baked.get(key, False):
        user[key] = True
with open('$TARGET', 'w') as f: json.dump(user, f, indent=2)
" 2>/dev/null || cp "$BAKED_SANDBOX" "$TARGET"
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
