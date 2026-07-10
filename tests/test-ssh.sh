#!/usr/bin/env bash
# Test SSH key loading from 1Password (ssh-use/ssh-unuse, adr/0004) and the
# container-local agent bootstrap (bin/ensure-ssh-agent).
# Uses mock-op.sh to intercept 1Password CLI calls and a real ssh-agent on a
# test-private socket. Runs standalone and in CI (no interactive shell needed
# — functions are extracted from dotfiles/.bashrc like test-env.sh does).
# No set -e or pipefail — test pass/fail is tracked via PASS/FAIL counters.
set -u

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test fixtures setup
# ---------------------------------------------------------------------------
TESTDIR=$(mktemp -d)
cleanup() {
    pkill -f "ssh-agent -a ${TESTDIR}/agent.sock" 2>/dev/null
    rm -rf "$TESTDIR"
}
trap cleanup EXIT

# Mock op binary — prepend to PATH so ssh-use calls our mock instead of real op
mkdir -p "$TESTDIR/bin"
cp "$SCRIPT_DIR/mock-op.sh" "$TESTDIR/bin/op"
export PATH="$TESTDIR/bin:$PATH"

# If ssh-use is not already defined (not running in an interactive devcontainer
# shell), extract the function definitions from dotfiles/.bashrc.
if ! type -t ssh-use &>/dev/null; then
    _bashrc_funcs="$TESTDIR/bashrc-funcs.sh"
    sed -n '/^# Environment switching via 1Password/,/^# Cursor\/VS Code/{/^# Cursor\/VS Code/!p}' \
        "$REPO_DIR/dotfiles/.bashrc" > "$_bashrc_funcs"
    # shellcheck disable=SC1090
    source "$_bashrc_funcs"
fi

# Throwaway keypairs served through the mock via file: indirection (SSH keys
# are multi-line; the secrets file itself is line-based)
mkdir -p "$TESTDIR/keys"
ssh-keygen -t ed25519 -f "$TESTDIR/keys/k1" -N '' -q -C "testkey@mock"
ssh-keygen -t ed25519 -f "$TESTDIR/keys/k2" -N '' -q -C "otherkey@mock"

export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << EOF
op://lab_ssh/testkey/private key?ssh-format=openssh=file:$TESTDIR/keys/k1
op://lab_ssh/testkey/public key=file:$TESTDIR/keys/k1.pub
op://lab_ssh/otherkey/private key?ssh-format=openssh=file:$TESTDIR/keys/k2
op://lab_ssh/otherkey/public key=file:$TESTDIR/keys/k2.pub
EOF
export MOCK_OP_LOG="$TESTDIR/op-calls.log"

agent_key_count() { ssh-add -l 2>/dev/null | grep -c "^[0-9]"; }

# =========================================================================
#  Tests: bin/ensure-ssh-agent
# =========================================================================
echo "==> Testing ensure-ssh-agent..."

export SSH_AUTH_SOCK="$TESTDIR/agent.sock"

output=$("$REPO_DIR/bin/ensure-ssh-agent" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Started ssh-agent"; then
    ok "starts a fresh agent"
else
    fail "starts a fresh agent (rc=$rc output: $output)"
fi
if [ -S "$SSH_AUTH_SOCK" ]; then
    ok "agent socket created at SSH_AUTH_SOCK"
else
    fail "agent socket created at SSH_AUTH_SOCK"
fi
# rc 1 from ssh-add -l = agent alive but empty — the required starting state
ssh-add -l >/dev/null 2>&1
rc=$?
if [ $rc -eq 1 ]; then
    ok "agent starts empty (no ambient keys)"
else
    fail "agent starts empty (ssh-add -l rc=$rc)"
fi

output=$("$REPO_DIR/bin/ensure-ssh-agent" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Reusing ssh-agent"; then
    ok "second run reuses the live agent"
else
    fail "second run reuses the live agent (rc=$rc output: $output)"
fi

# Stale socket file (no agent behind it) gets replaced
STALE_DIR=$(mktemp -d "$TESTDIR/stale.XXXXXX")
touch "$STALE_DIR/agent.sock"
output=$(SSH_AUTH_SOCK="$STALE_DIR/agent.sock" "$REPO_DIR/bin/ensure-ssh-agent" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Started ssh-agent"; then
    ok "stale socket file is replaced with a fresh agent"
else
    fail "stale socket file is replaced (rc=$rc output: $output)"
fi
pkill -f "ssh-agent -a ${STALE_DIR}/agent.sock" 2>/dev/null

# =========================================================================
#  Tests: ssh-use
# =========================================================================
echo ""
echo "==> Testing ssh-use..."

ssh-use testkey > /dev/null 2>&1
rc=$?
if [ $rc -eq 0 ] && [ "$(agent_key_count)" = "1" ]; then
    ok "ssh-use loads key into agent"
else
    fail "ssh-use loads key into agent (rc=$rc count=$(agent_key_count))"
fi
if ssh-add -l | grep -q "testkey@mock"; then
    ok "loaded key is the requested one"
else
    fail "loaded key is the requested one ($(ssh-add -l))"
fi
if grep -q "op read op://lab_ssh/testkey/private key?ssh-format=openssh" "$MOCK_OP_LOG"; then
    ok "key requested in openssh format"
else
    fail "key requested in openssh format"
fi

# Re-running is idempotent (re-adds the same key, count stays 1)
ssh-use testkey > /dev/null 2>&1
if [ "$(agent_key_count)" = "1" ]; then
    ok "ssh-use is idempotent"
else
    fail "ssh-use is idempotent (count=$(agent_key_count))"
fi

# Failed op read → nonzero rc, error message, agent state unchanged
output=$(ssh-use missing 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -q "Failed to load SSH key 'missing'"; then
    ok "missing key fails loudly"
else
    fail "missing key fails loudly (rc=$rc output: $output)"
fi
if [ "$(agent_key_count)" = "1" ]; then
    ok "failed ssh-use leaves agent unchanged"
else
    fail "failed ssh-use leaves agent unchanged (count=$(agent_key_count))"
fi

# =========================================================================
#  Tests: ssh-unuse
# =========================================================================
echo ""
echo "==> Testing ssh-unuse..."

ssh-use otherkey > /dev/null 2>&1
if [ "$(agent_key_count)" = "2" ]; then
    ok "second key loads alongside first"
else
    fail "second key loads alongside first (count=$(agent_key_count))"
fi

ssh-unuse testkey > /dev/null 2>&1
rc=$?
if [ $rc -eq 0 ] && [ "$(agent_key_count)" = "1" ]; then
    ok "ssh-unuse removes only the named key"
else
    fail "ssh-unuse removes only the named key (rc=$rc count=$(agent_key_count))"
fi
if ssh-add -l | grep -q "otherkey@mock"; then
    ok "remaining key is the other one"
else
    fail "remaining key is the other one ($(ssh-add -l))"
fi

output=$(ssh-unuse missing 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -q "Failed to remove"; then
    ok "unuse of unknown key fails loudly"
else
    fail "unuse of unknown key fails loudly (rc=$rc output: $output)"
fi

ssh-unuse > /dev/null 2>&1
ssh-add -l >/dev/null 2>&1
if [ $? -eq 1 ]; then
    ok "bare ssh-unuse clears all keys"
else
    fail "bare ssh-unuse clears all keys ($(ssh-add -l 2>&1))"
fi

# =========================================================================
#  Tests: key lifetime (TTL)
# =========================================================================
echo ""
echo "==> Testing key lifetime..."

SSH_USE_TTL=1 ssh-use testkey > /dev/null 2>&1
if [ "$(agent_key_count)" = "1" ]; then
    ok "key loaded with 1s TTL"
else
    fail "key loaded with 1s TTL (count=$(agent_key_count))"
fi
sleep 2
ssh-add -l >/dev/null 2>&1
if [ $? -eq 1 ]; then
    ok "key expires from agent after TTL"
else
    fail "key expires from agent after TTL ($(ssh-add -l 2>&1))"
fi

# =========================================================================
#  Results
# =========================================================================
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
