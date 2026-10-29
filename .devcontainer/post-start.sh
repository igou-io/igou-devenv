#!/usr/bin/env bash
# Runs every time the container starts (not just on creation).
set -euo pipefail

if [ -n "${CI:-}" ]; then
    echo "==> CI detected, skipping post-start checks"
    exit 0
fi

# Poll until a background service is listening on its port (up to 15s).
# The long-lived t3 service is forked near the end of this
# script; when it runs as a devcontainer-CLI postStart exec, the exec
# session is torn down as soon as the script exits and can reap a child
# that is still mid-startup. Waiting for the listen socket keeps the
# script alive past that window and makes a failed start loud instead of
# silent. Non-fatal: a WARN never blocks the rest of post-start.
wait_for_listen() {
    port=$1 svc=$2 log=$3
    for _ in $(seq 1 30); do
        if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            echo "    ${svc} listening on :${port}"
            return 0
        fi
        sleep 0.5
    done
    echo "    WARNING (non-fatal): ${svc} not listening on :${port} after 15s (see ${log})"
    return 0
}

# ---------------------------------------------------------------------------
# Container-local SSH agent (igou-docs/devenv/Devenv Environment and Credential Decisions.md)
# No host agent forwarding: a dedicated agent listens on the fixed socket
# path devcontainer.json exports as SSH_AUTH_SOCK. It starts empty — load
# keys on demand from 1Password with ssh-use (dotfiles/.bashrc).
# Non-fatal: agent bootstrap must not block the rest of post-start.
# ---------------------------------------------------------------------------
echo "==> Ensuring container-local SSH agent..."
/workspace/igou-devenv/bin/ensure-ssh-agent 2>&1 | sed 's/^/    /' \
    || echo "    WARNING (non-fatal): SSH agent setup failed"


# ---------------------------------------------------------------------------
# Writable-layer hygiene (igou-devenv#187): nested podman images, stale
# scratchpads, old CLI versions, package caches. Non-fatal.
# ---------------------------------------------------------------------------
echo "==> Pruning container writable layer..."
/workspace/igou-devenv/.devcontainer/hygiene.sh 2>&1 \
    || echo "    WARNING (non-fatal): hygiene pass failed"

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
# t3 serve — T3 Code, a headless web GUI for the coding-agent CLIs in this
# image (claude/codex/opencode/cursor-agent), started always-on.
# State (device pairing credentials, thread history) lives
# in ~/.t3, a persistent bind mount, so paired browsers survive container
# rebuilds. Binds all interfaces (the container is --network=host), so the
# service is reachable on every network the host is on. There is no
# password gate — device pairing is the only barrier, and a
# paired session executes arbitrary commands as this user — so anyone who
# can reach the port can attempt pairing. Acceptable for this trusted
# single-user homelab network; set T3CODE_HOST to a specific address (e.g.
# the tailnet IP) to narrow exposure. The pairing URL + QR code land in
# ~/.t3/serve.log on first start; manage/revoke devices with `t3 auth`.
# Idempotent: skips if the port is already being served.
# ---------------------------------------------------------------------------
if command -v t3 >/dev/null 2>&1; then
    T3_PORT="${T3CODE_PORT:-3773}"
    T3_HOST="${T3CODE_HOST:-0.0.0.0}"
    mkdir -p "$HOME/.t3"
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${T3_PORT}\$"; then
        echo "==> t3 serve already listening on :${T3_PORT}"
    else
        echo "==> Starting t3 serve on ${T3_HOST}:${T3_PORT} (pairing info: ~/.t3/serve.log)..."
        # setsid + wait_for_listen prevent the teardown race. t3 is the
        # last service this script starts, so
        # under the AAP bootstrap's postStart exec it sat closest to the
        # session teardown and was reliably reaped mid-startup.
        setsid nohup t3 serve --host "$T3_HOST" >> "$HOME/.t3/serve.log" 2>&1 < /dev/null &
        disown || true
        wait_for_listen "$T3_PORT" "t3 serve" "$HOME/.t3/serve.log"
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
