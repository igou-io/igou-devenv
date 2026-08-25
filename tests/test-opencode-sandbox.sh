#!/usr/bin/env bash
# Verifies the opencode 1Password sandbox shim (adr/0005) is wired and effective.
#
# Static checks (always): the ~/.local/bin/opencode symlink resolves to the shim,
# and the shim is an executable, syntactically valid script.
#
# Runtime checks: launch a real `opencode serve` through the shim and assert the
# listening process runs in a mount namespace that masks ~/.config/op and has
# CAP_SYS_ADMIN dropped. The op-specific assertions are skipped when the
# ~/.config/op bind mount is absent (e.g. CI without host credentials); the
# namespace/capability assertions still run.
set -euo pipefail

SHIM="$HOME/.local/bin/opencode-sandbox"
LINK="$HOME/.local/bin/opencode"
fail() { echo "  [FAIL] $1" >&2; exit 1; }
ok() { echo "  [OK] $1"; }

echo "==> Static wiring"
[ -x "$SHIM" ] || fail "shim missing or not executable: $SHIM"
sh -n "$SHIM" || fail "shim is not valid shell"
target="$(readlink -f "$LINK" 2>/dev/null || true)"
[ "$target" = "$(readlink -f "$SHIM")" ] || fail "opencode symlink -> '$target', expected the shim"
ok "opencode resolves to the sandbox shim"

# The runtime checks need an unprivileged user namespace, which some CI runners
# restrict. Treat its absence as diagnostic (like test-sandbox-primitives)
# unless REQUIRE_OPENCODE_SANDBOX=true.
REQUIRE_OPENCODE_SANDBOX="${REQUIRE_OPENCODE_SANDBOX:-false}"
if ! unshare -Ur true 2>/dev/null; then
    if [ "$REQUIRE_OPENCODE_SANDBOX" = "true" ]; then
        fail "user namespaces unavailable and REQUIRE_OPENCODE_SANDBOX=true"
    fi
    echo "  [SKIP] user namespaces unavailable; runtime sandbox checks skipped"
    echo "==> opencode 1Password sandbox static checks passed"
    exit 0
fi

echo "==> Runtime: launch opencode serve through the shim"
PORT=$(( (RANDOM % 20000) + 20000 ))
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
OPENCODE_CONFIG_CONTENT='{}' "$LINK" serve --hostname=127.0.0.1 --port="$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 60); do
    grep -q 'opencode server listening' "$LOG" && break
    sleep 0.5
done
grep -q 'opencode server listening' "$LOG" || { cat "$LOG" >&2; fail "server did not report ready"; }
PID="$(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)"
[ -n "${PID:-}" ] || fail "could not find opencode listener pid"
ok "server listening (pid $PID)"

# CAP_SYS_ADMIN (bit 21) must be cleared from the bounding set.
capbnd="$(awk '/^CapBnd:/{print $2}' "/proc/$PID/status")"
if python3 -c "import sys; sys.exit(0 if not ((int('$capbnd',16)>>21)&1) else 1)"; then
    ok "CAP_SYS_ADMIN dropped in the server's bounding set"
else
    kill "$PID" 2>/dev/null || true
    fail "CAP_SYS_ADMIN still present (CapBnd=$capbnd) — agent could umount the mask"
fi

if [ -d "$HOME/.config/op" ] && { [ -e "$HOME/.config/op/connect-token" ] || [ -e "$HOME/.config/op/service-account-token" ]; }; then
    if grep ' /home/[^ ]*/.config/op ' "/proc/$PID/mountinfo" | grep -q tmpfs; then
        ok "op config dir masked by tmpfs in the server mount namespace"
    else
        kill "$PID" 2>/dev/null || true
        fail "op config dir is NOT masked in the server namespace — token exposed"
    fi
else
    echo "  [SKIP] op credentials absent; namespace mask assertion skipped"
fi

kill "$PID" 2>/dev/null || true
echo "==> opencode 1Password sandbox checks passed"
