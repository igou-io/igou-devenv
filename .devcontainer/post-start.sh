#!/usr/bin/env bash
# Runs every time the container starts (not just on creation).
set -euo pipefail

if [ -n "${CI:-}" ]; then
    echo "==> CI detected, skipping post-start checks"
    exit 0
fi

# ---------------------------------------------------------------------------
# Container-local SSH agent (adr/0004)
# No host agent forwarding: a dedicated agent listens on the fixed socket
# path devcontainer.json exports as SSH_AUTH_SOCK. It starts empty — load
# keys on demand from 1Password with ssh-use (dotfiles/.bashrc).
# Non-fatal: agent bootstrap must not block the rest of post-start.
# ---------------------------------------------------------------------------
echo "==> Ensuring container-local SSH agent..."
/workspace/igou-devenv/bin/ensure-ssh-agent 2>&1 | sed 's/^/    /' \
    || echo "    WARNING (non-fatal): SSH agent setup failed"


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
# Start the D-Bus system bus. libvirt's URI resolver (`qemu:///system`)
# uses D-Bus to discover the modular daemon sockets, so we need a system
# bus running before the libvirt daemons are useful via the standard URI.
# Idempotent: skips if dbus-daemon is already running. Checks /proc/*/comm
# directly because `pgrep` is not in this container image, and the socket
# file under /run can be a stale tmpfs leftover from a prior container.
# ---------------------------------------------------------------------------
if command -v dbus-daemon >/dev/null 2>&1; then
    if grep -q dbus-daemon /proc/[0-9]*/comm 2>/dev/null; then
        echo "==> dbus-daemon already running"
    else
        echo "==> Starting dbus-daemon (system bus)..."
        sudo rm -f /run/dbus/system_bus_socket
        sudo mkdir -p /run/dbus
        sudo dbus-daemon --system --fork --nopidfile
        for _ in 1 2 3; do
            [ -S /run/dbus/system_bus_socket ] && break
            sleep 1
        done
        if [ -S /run/dbus/system_bus_socket ]; then
            echo "    system bus socket ready at /run/dbus/system_bus_socket"
        else
            echo "    WARNING: dbus system bus socket did not appear within 3s"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Start the modular libvirt daemons (virtqemud, virtnetworkd, virtstoraged) so
# the community.libvirt Ansible modules and `virsh -c qemu:///system` all work.
# systemd is not running here, so we start each daemon directly. polkitd is not
# present in this container, so we disable polkit auth and fall back to
# socket-permission-only auth (auth_unix = "none"). Idempotent: skips daemons
# that already have a socket.
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
# code-server — browser-based VS Code, started always-on. Bound to 0.0.0.0
# (the container runs --network=host) so it's reachable on the host's network.
# The container is --privileged with /dev bind-mounted, so reaching this port
# grants a terminal with full host access — password auth is mandatory. The
# config (bind-addr + auth) ships in ~/.config/code-server/config.yaml via
# post-create.sh; we ensure a password is present (generated once, persisted
# in the config — read it with `cat ~/.config/code-server/config.yaml`) and
# launch detached. Idempotent: skips if the port is already being served.
# Note: this block is skipped in CI (the early exit at the top of this script).
# ---------------------------------------------------------------------------
if command -v code-server >/dev/null 2>&1; then
    CS_CONFIG="$HOME/.config/code-server/config.yaml"
    mkdir -p "$HOME/.config/code-server" "$HOME/.local/share/code-server"
    # Defensive: reinstall config if post-create did not run (e.g. bare restart).
    if [ ! -f "$CS_CONFIG" ]; then
        cp /workspace/igou-devenv/dotfiles/code-server-config.yaml "$CS_CONFIG"
    fi
    CS_PORT=$(awk -F: '/^bind-addr:/{print $NF; exit}' "$CS_CONFIG")
    CS_PORT="${CS_PORT:-8080}"
    # Ensure an auth password exists — auth: password is useless without one.
    if ! grep -qE '^(password|hashed-password):' "$CS_CONFIG"; then
        printf 'password: %s\n' "$(openssl rand -hex 24)" >> "$CS_CONFIG"
    fi
    # Bridge devcontainer.json customizations (editor settings + Open VSX
    # extensions) into code-server — it does not read devcontainer.json itself.
    # Runs before launch so a fresh start comes up with highlighting in place;
    # idempotent and fast on warm starts (extensions already installed). The
    # data dir is a persistent bind mount, so this populates it once per host.
    CS_SYNC=/workspace/igou-devenv/.devcontainer/code-server-sync.sh
    if [ -f "$CS_SYNC" ]; then
        bash "$CS_SYNC" \
            /workspace/igou-devenv/.devcontainer/devcontainer.json \
            "$HOME/.local/share/code-server" || echo "    code-server-sync failed (non-fatal)"
    fi
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${CS_PORT}\$"; then
        echo "==> code-server already listening on :${CS_PORT}"
    else
        echo "==> Starting code-server on 0.0.0.0:${CS_PORT} (password in ${CS_CONFIG})..."
        nohup code-server /workspace >> "$HOME/.local/share/code-server/code-server.log" 2>&1 &
        disown || true
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
