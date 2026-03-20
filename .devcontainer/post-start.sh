#!/usr/bin/env bash
# Runs every time the container starts (not just on creation).
# Checks SSH agent state, which can change between restarts.
set -euo pipefail

if [ -n "${CI:-}" ]; then
    echo "==> CI detected, skipping SSH agent check"
    exit 0
fi

echo "==> Checking SSH agent forwarding..."
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    echo "    SSH_AUTH_SOCK is set: ${SSH_AUTH_SOCK}"
    ssh-add -l 2>/dev/null && echo "    Agent has keys loaded" || echo "    WARNING: Agent is reachable but has no keys"
else
    echo "    WARNING: SSH_AUTH_SOCK is not set. Private repo clones will fail."
    echo "    Make sure your SSH agent is running and Cursor is forwarding it."
fi

# Always use SSH for GitHub so forwarded keys work
git config --global url."git@github.com:".insteadOf "https://github.com/"
