#!/usr/bin/env bash
# Runs every time the container starts (not just on creation).
# Checks SSH agent state, which can change between restarts.
set -euo pipefail

if [ -n "${CI:-}" ]; then
    echo "==> CI detected, skipping post-start checks"
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
    if [ -n "${SSH_AUTH_SOCK:-}" ] && timeout 2 ssh-add -l &>/dev/null; then
        return 0
    fi
    # Scan cursor/vscode symlinks, newest first
    for sock in $(ls -t /tmp/cursor-remote-ssh-auth-*.sock /tmp/vscode-ssh-auth-*.sock 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" timeout 2 ssh-add -l &>/dev/null; then
            export SSH_AUTH_SOCK="$sock"
            return 0
        fi
    done
    # Fallback to raw ssh-agent sockets
    for sock in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" timeout 2 ssh-add -l &>/dev/null; then
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


# ---------------------------------------------------------------------------
# Docker socket permissions — match the docker group GID to the socket's GID
# so the non-root user can access it without socat proxying.
# ---------------------------------------------------------------------------
if [ -S /var/run/docker.sock ]; then
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    SOCK_GROUP=$(getent group "$SOCK_GID" | cut -d: -f1 || true)
    if ! getent group docker &>/dev/null; then
        if [ -z "$SOCK_GROUP" ]; then
            sudo groupadd -g "$SOCK_GID" docker
            SOCK_GROUP="docker"
        fi
    else
        CURRENT_GID=$(getent group docker | cut -d: -f3)
        if [ "$CURRENT_GID" != "$SOCK_GID" ]; then
            sudo groupmod -g "$SOCK_GID" docker
        fi
        SOCK_GROUP="docker"
    fi
    if [ -n "$SOCK_GROUP" ] && ! id -nG | grep -qw "$SOCK_GROUP"; then
        sudo usermod -aG "$SOCK_GROUP" "$(whoami)"
    fi
fi

# ---------------------------------------------------------------------------
# Start virtqemud (modular libvirt daemon) so community.libvirt modules and
# `virsh -c qemu:///system` work inside the container. systemd is not running
# here, so we start virtqemud directly as a background process if it isn't
# already running. Idempotent: skips if already up.
#
# polkit/D-Bus is absent in this container, so set auth_unix_rw/ro = "none"
# in virtqemud.conf before starting the daemon; the sed is idempotent.
# ---------------------------------------------------------------------------
if command -v virtqemud >/dev/null 2>&1; then
    # Disable polkit auth (requires D-Bus) so non-root users can connect.
    VQEMUD_CONF=/etc/libvirt/virtqemud.conf
    if sudo grep -q '^#auth_unix_rw' "$VQEMUD_CONF" 2>/dev/null; then
        sudo sed -i \
            's|^#auth_unix_ro = "polkit"|auth_unix_ro = "none"|;
             s|^#auth_unix_rw = "polkit"|auth_unix_rw = "none"|' \
            "$VQEMUD_CONF"
    fi
    if [ ! -S /var/run/libvirt/virtqemud-sock ]; then
        echo "==> Starting virtqemud..."
        sudo mkdir -p /var/run/libvirt /var/log/libvirt
        sudo virtqemud --daemon
        # Wait up to 3s for the socket to appear
        for _ in 1 2 3; do
            [ -S /var/run/libvirt/virtqemud-sock ] && break
            sleep 1
        done
        if [ -S /var/run/libvirt/virtqemud-sock ]; then
            echo "    virtqemud socket ready at /var/run/libvirt/virtqemud-sock"
        else
            echo "    WARNING: virtqemud socket did not appear within 3s"
        fi
    else
        echo "==> virtqemud already running"
    fi
fi

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
