#!/bin/bash
# Container entrypoint: configure git identity, merge MCP config, and GitHub PAT auth.
# Writes to /tmp because the root filesystem is read-only.

# Merge baked configs from /etc/claude/ into user configs.
# These baked configs define MCP servers and sandbox settings for the container.
# When host files are bind-mounted, baked values are merged in (baked takes precedence).
# When no host file exists, the baked config is copied as-is.
MERGE_SCRIPT="/usr/local/lib/claude-container/merge-config.py"

merge_json() {
    local baked="$1" target="$2"; shift 2
    if [ -f "$baked" ]; then
        if [ -f "$target" ]; then
            python3 "$MERGE_SCRIPT" "$baked" "$target" "$@" 2>/dev/null || cp "$baked" "$target"
        else
            cp "$baked" "$target"
        fi
    fi
}

# Seed ~/.claude.json from the snapshot created by claude-run, then merge baked MCP config.
# claude-run copies the host's ~/.claude.json to ~/.claude/.claude-state.json (inside the
# mounted directory) to avoid file bind mounts that break on atomic writes.
# Skip seeding when using API key or third-party provider auth — seeding the host's
# OAuth tokens would cause an "auth conflict" warning in Claude Code.
# ANTHROPIC_API_KEY: direct Anthropic API usage
# ANTHROPIC_AUTH_TOKEN: third-party providers (e.g., OpenRouter)
STATE_SNAPSHOT="$HOME/.claude/.claude-state.json"
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -f "$STATE_SNAPSHOT" ] && [ ! -f "$HOME/.claude.json" ]; then
    cp "$STATE_SNAPSHOT" "$HOME/.claude.json"
fi

# ~/.claude.json — merge baked mcpServers
merge_json "/etc/claude/claude.json" "$HOME/.claude.json" --key mcpServers

# ~/.claude/settings.json — deep-merge baked sandbox settings
merge_json "/etc/claude/settings.json" "$HOME/.claude/settings.json"

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
