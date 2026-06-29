#!/usr/bin/env bash
# Diagnostic checks for sandbox-related kernel/runtime primitives.
# Missing commands are hard failures. Runtime primitive failures are diagnostic
# by default and become fatal only with REQUIRE_SANDBOX_PRIMITIVES=true.
set -euo pipefail

REQUIRE_SANDBOX_PRIMITIVES="${REQUIRE_SANDBOX_PRIMITIVES:-false}"
RUNTIME_FAILURES=0

runtime_check() {
    local name="$1"
    shift

    echo ""
    echo "==> Runtime check: ${name}"
    if "$@"; then
        echo "  [OK] ${name}"
    else
        local status=$?
        echo "  [WARN] ${name} failed with exit status ${status}"
        RUNTIME_FAILURES=$((RUNTIME_FAILURES + 1))
    fi
}

echo "==> Command availability"
command -v bwrap
bwrap --version
command -v rg
rg --version
command -v unshare
unshare --version

echo ""
echo "==> Namespace maps"
cat /proc/self/uid_map
cat /proc/self/gid_map

runtime_check "unprivileged user namespace" unshare -Ur true
runtime_check "minimal bubblewrap sandbox" \
    bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp true

echo ""
if [ "$RUNTIME_FAILURES" -eq 0 ]; then
    echo "==> Sandbox primitive runtime checks passed"
elif [ "$REQUIRE_SANDBOX_PRIMITIVES" = "true" ]; then
    echo "==> Sandbox primitive runtime checks failed and REQUIRE_SANDBOX_PRIMITIVES=true"
    exit 1
else
    echo "==> Sandbox primitive runtime checks had ${RUNTIME_FAILURES} diagnostic failure(s)"
    echo "==> Not failing because REQUIRE_SANDBOX_PRIMITIVES is not true"
fi
