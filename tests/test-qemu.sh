#!/usr/bin/env bash
# Verify QEMU userspace and (Phase 2) libvirt stack inside the devcontainer.
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Verifying QEMU userspace..."

# Phase 1 binaries
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

# Python libvirt binding — community.libvirt requires this
if python3 -c 'import libvirt' 2>/dev/null; then
    ok "python3-libvirt bindings importable"
else
    fail "python3-libvirt bindings importable"
fi

# Galaxy collection
if ansible-galaxy collection list community.libvirt 2>/dev/null | grep -q community.libvirt; then
    ok "community.libvirt collection installed"
else
    fail "community.libvirt collection installed"
fi

# Group membership
for g in libvirt kvm; do
    if id -nG | grep -qw "$g"; then
        ok "igou is a member of $g group"
    else
        fail "igou is a member of $g group"
    fi
done

# virtqemud socket reachable (daemon started by post-start.sh)
echo ""
echo "==> Verifying virtqemud socket..."
if virsh -c qemu:///system list >/dev/null 2>&1; then
    ok "virsh can talk to qemu:///system"
else
    fail "virsh can talk to qemu:///system"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
