#!/usr/bin/env bash
# Verify QEMU userspace and (Phase 2) libvirt stack inside the devcontainer.
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Verifying QEMU userspace..."

declare -A QEMU_TOOLS=(
    [qemu-system-x86_64]="qemu-system-x86_64 --version"
    [qemu-img]="qemu-img --version"
    [genisoimage]="genisoimage --version"
)

for tool in $(echo "${!QEMU_TOOLS[@]}" | tr ' ' '\n' | sort); do
    if version=$(${QEMU_TOOLS[$tool]} 2>&1 | head -1) && [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool"
    fi
done

# /dev/kvm reachability (TCG fallback is fine, but we want to know which we got)
echo ""
echo "==> Verifying /dev/kvm..."
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm is a readable+writable char device"
else
    echo "  [WARN] /dev/kvm not accessible — guests will fall back to TCG (slow)"
fi

# Tiny TCG smoke boot — confirms qemu-system-x86_64 actually runs.
# `-kernel /dev/null` makes QEMU exit immediately with a controlled error.
echo ""
echo "==> Smoke-booting QEMU under TCG..."
SMOKE_LOG=$(mktemp /tmp/qemu-smoke.XXXXXX.log)
trap 'rm -f "$SMOKE_LOG"' EXIT
if timeout 10 qemu-system-x86_64 -accel tcg -nographic -no-reboot \
       -kernel /dev/null -display none </dev/null >"$SMOKE_LOG" 2>&1; then
    ok "qemu-system-x86_64 launched and exited cleanly"
else
    rc=$?
    # rc=1 with "kernel too short" or "no bootable device" is the success signal.
    if grep -qiE "kernel.*too short|No bootable device|could not load" "$SMOKE_LOG"; then
        ok "qemu-system-x86_64 launched (got expected boot failure)"
    else
        fail "qemu-system-x86_64 smoke boot failed (rc=$rc): $(head -3 "$SMOKE_LOG")"
    fi
fi

echo ""
echo "==> Verifying libvirt stack..."

declare -A LIBVIRT_TOOLS=(
    [virsh]="virsh --version"
    [virtqemud]="virtqemud --version"
)

for tool in $(echo "${!LIBVIRT_TOOLS[@]}" | tr ' ' '\n' | sort); do
    if version=$(${LIBVIRT_TOOLS[$tool]} 2>&1 | head -1) && [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool"
    fi
done

# Python libvirt binding
if python3 -c 'import libvirt' 2>/dev/null; then
    ok "python3-libvirt bindings importable"
else
    fail "python3-libvirt bindings importable"
fi

# Group membership.
# `id -nG` exits non-zero when a supplementary GID has no name entry in the
# container (e.g. the host's kvm GID added via `--group-add=994` so /dev/kvm is
# accessible). Capture its output and swallow that exit so `pipefail` doesn't
# fail the check when membership is actually correct.
member_groups=$(id -nG 2>/dev/null || true)
for g in libvirt kvm; do
    if grep -qw "$g" <<<"$member_groups"; then
        ok "igou is a member of $g group"
    else
        fail "igou is a member of $g group"
    fi
done

# Modular libvirt daemons (qemu domains, networks, storage)
echo ""
echo "==> Verifying libvirt subsystems..."
for d in virtqemud virtnetworkd virtstoraged; do
    if [ -S "/var/run/libvirt/${d}-sock" ]; then
        ok "${d} socket reachable"
    else
        fail "${d} socket reachable"
    fi
done

# Functional checks via virsh
if virsh -c qemu:///system list --all >/dev/null 2>&1; then
    ok "virsh list (domains, via virtqemud)"
else
    fail "virsh list (domains, via virtqemud)"
fi
if virsh -c qemu:///system net-list --all >/dev/null 2>&1; then
    ok "virsh net-list (networks, via virtnetworkd)"
else
    fail "virsh net-list (networks, via virtnetworkd)"
fi
if virsh -c qemu:///system pool-list --all >/dev/null 2>&1; then
    ok "virsh pool-list (storage, via virtstoraged)"
else
    fail "virsh pool-list (storage, via virtstoraged)"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
