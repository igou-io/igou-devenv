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
if timeout 10 qemu-system-x86_64 -accel tcg -nographic -no-reboot \
       -kernel /dev/null -display none </dev/null >/tmp/qemu-smoke.log 2>&1; then
    ok "qemu-system-x86_64 launched and exited cleanly"
else
    rc=$?
    # rc=1 with "kernel too short" or "no bootable device" is the success signal.
    if grep -qE "kernel.*too short|No bootable device|Could not load" /tmp/qemu-smoke.log; then
        ok "qemu-system-x86_64 launched (got expected boot failure)"
    else
        fail "qemu-system-x86_64 smoke boot failed (rc=$rc): $(head -3 /tmp/qemu-smoke.log)"
    fi
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
