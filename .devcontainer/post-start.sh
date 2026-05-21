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
# Start the modular libvirt daemons (virtqemud, virtnetworkd, virtstoraged) so
# the community.libvirt Ansible modules and `virsh -c qemu:///system` all work.
# systemd is not running here, so we start each daemon directly. The default
# polkit auth in each daemon's config breaks because there's no D-Bus, so we
# fall back to socket-permission-only auth (auth_unix = "none"). Idempotent:
# skips daemons that already have a socket.
# ---------------------------------------------------------------------------
for d in virtqemud virtnetworkd virtstoraged; do
    if ! command -v "$d" >/dev/null 2>&1; then
        continue
    fi
    sock="/var/run/libvirt/${d}-sock"
    conf="/etc/libvirt/${d}.conf"
    if [ -S "$sock" ]; then
        echo "==> $d already running"
        continue
    fi
    echo "==> Starting $d..."
    if [ -f "$conf" ] && sudo grep -q '^#auth_unix_rw' "$conf" 2>/dev/null; then
        sudo sed -i \
            -e 's/^#auth_unix_ro = "polkit"/auth_unix_ro = "none"/' \
            -e 's/^#auth_unix_rw = "polkit"/auth_unix_rw = "none"/' \
            "$conf"
    fi
    sudo mkdir -p /var/run/libvirt /var/log/libvirt
    sudo "$d" --daemon
    for _ in 1 2 3; do
        [ -S "$sock" ] && break
        sleep 1
    done
    if [ -S "$sock" ]; then
        echo "    $d socket ready at $sock"
    else
        echo "    WARNING: $d socket did not appear within 3s"
    fi
done

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
