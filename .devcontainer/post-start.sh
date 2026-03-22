#!/usr/bin/env bash
# Runs every time the container starts (not just on creation).
# Checks SSH agent state, which can change between restarts.
set -euo pipefail

if [ -n "${CI:-}" ]; then
    echo "==> CI detected, skipping SSH agent check"
    exit 0
fi

# ---------------------------------------------------------------------------
# Find a working SSH agent socket
# Cursor/VS Code create new symlinks on reconnect but leave SSH_AUTH_SOCK
# pointing at stale ones. Test the current socket, and if it's dead, scan
# for a working one.
# ---------------------------------------------------------------------------
find_working_ssh_sock() {
    # Try current socket first
    if [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l &>/dev/null; then
        return 0
    fi
    # Scan cursor/vscode symlinks, newest first
    for sock in $(ls -t /tmp/cursor-remote-ssh-auth-*.sock /tmp/vscode-ssh-auth-*.sock 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" ssh-add -l &>/dev/null; then
            export SSH_AUTH_SOCK="$sock"
            return 0
        fi
    done
    # Fallback to raw ssh-agent sockets
    for sock in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" ssh-add -l &>/dev/null; then
            export SSH_AUTH_SOCK="$sock"
            return 0
        fi
    done
    return 1
}

echo "==> Checking SSH agent forwarding..."
if find_working_ssh_sock; then
    echo "    SSH_AUTH_SOCK is set: ${SSH_AUTH_SOCK}"
    echo "    Agent has keys loaded"
else
    echo "    WARNING: No working SSH agent socket found."
    echo "    Make sure your SSH agent is running and Cursor is forwarding it."
fi

# Always use SSH for GitHub so forwarded keys work
git config --global url."git@github.com:".insteadOf "https://github.com/"

# ---------------------------------------------------------------------------
# Restore Claude Code config if missing (backup lives in mounted ~/.claude/)
# ---------------------------------------------------------------------------
if [ ! -f "$HOME/.claude.json" ] && [ -d "$HOME/.claude/backups" ]; then
    BACKUP=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
    if [ -n "$BACKUP" ]; then
        cp "$BACKUP" "$HOME/.claude.json"
        echo "==> Restored Claude config from backup"
    fi
fi
