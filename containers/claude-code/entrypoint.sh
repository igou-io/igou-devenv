#!/bin/bash
# Container entrypoint: configure git identity, merge MCP config, and GitHub PAT auth.
# Writes to /tmp because the root filesystem is read-only.

# Merge baked MCP servers into ~/.claude.json (which may be bind-mounted from host).
# The baked config at /etc/claude/claude.json defines MCP servers for the container.
# If ~/.claude.json already exists (from host mount), merge mcpServers into it.
# Otherwise, copy the baked config as-is.
# Merge baked configs from /etc/claude/ into user configs.
# These baked configs define MCP servers and sandbox settings for the container.
# When host files are bind-mounted, baked values are merged in (baked takes precedence).
# When no host file exists, the baked config is copied as-is.
merge_json() {
    local baked="$1" target="$2" merge_script="$3"
    if [ -f "$baked" ]; then
        if [ -f "$target" ]; then
            python3 -c "$merge_script" 2>/dev/null || cp "$baked" "$target"
        else
            cp "$baked" "$target"
        fi
    fi
}

# Seed ~/.claude.json from the snapshot created by claude-run, then merge baked MCP config.
# claude-run copies the host's ~/.claude.json to ~/.claude/.claude-state.json (inside the
# mounted directory) to avoid file bind mounts that break on atomic writes.
STATE_SNAPSHOT="$HOME/.claude/.claude-state.json"
if [ -f "$STATE_SNAPSHOT" ] && [ ! -f "$HOME/.claude.json" ]; then
    cp "$STATE_SNAPSHOT" "$HOME/.claude.json"
fi

# ~/.claude.json — merge baked mcpServers
merge_json "/etc/claude/claude.json" "$HOME/.claude.json" "
import json
with open('$HOME/.claude.json') as f: user = json.load(f)
with open('/etc/claude/claude.json') as f: baked = json.load(f)
user.setdefault('mcpServers', {}).update(baked.get('mcpServers', {}))
with open('$HOME/.claude.json', 'w') as f: json.dump(user, f, indent=2)
"

# ~/.claude/settings.json — deep-merge baked sandbox settings
merge_json "/etc/claude/settings.json" "$HOME/.claude/settings.json" "
import json
with open('$HOME/.claude/settings.json') as f: user = json.load(f)
with open('/etc/claude/settings.json') as f: baked = json.load(f)
for key, val in baked.items():
    if isinstance(val, dict) and isinstance(user.get(key), dict):
        user[key].update(val)
    else:
        user[key] = val
with open('$HOME/.claude/settings.json', 'w') as f: json.dump(user, f, indent=2)
"

# Global CLAUDE.md — baked into image, copied only if user doesn't have one
if [ -f /etc/claude/CLAUDE.md ] && [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
    cp /etc/claude/CLAUDE.md "$HOME/.claude/CLAUDE.md"
fi

# Git config in /tmp (read-only root filesystem)
export GIT_CONFIG_GLOBAL="/tmp/.gitconfig"

git config --global user.name "claude[bot]"
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
