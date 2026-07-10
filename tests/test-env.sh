#!/usr/bin/env bash
# Test environment switching shell functions (use, unuse, k8s-unset, prompt).
# Run with bash -i (interactive) inside the devcontainer so .bashrc is sourced,
# or standalone — the script extracts functions from post-create.sh as a fallback.
# Uses mock-op.sh to intercept 1Password CLI calls.
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
trap 'rm -rf "$TESTDIR"' EXIT

# Mock op binary — prepend to PATH so use() calls our mock instead of real op
mkdir -p "$TESTDIR/bin"
cp "$SCRIPT_DIR/mock-op.sh" "$TESTDIR/bin/op"
export PATH="$TESTDIR/bin:$PATH"

# If use() is not already defined (not running inside devcontainer), extract
# the function definitions from dotfiles/.bashrc and source them.
if ! type -t use &>/dev/null; then
    _bashrc_funcs="$TESTDIR/bashrc-funcs.sh"
    # Extract environment switching functions from dotfiles/.bashrc.
    # Grabs from "Environment switching" through the "Cursor/VS Code" comment (exclusive).
    sed -n '/^# Environment switching via 1Password/,/^# Cursor\/VS Code/{/^# Cursor\/VS Code/!p}' \
        "$REPO_DIR/dotfiles/.bashrc" > "$_bashrc_funcs"
    # shellcheck disable=SC1090
    source "$_bashrc_funcs"
    # Provide a minimal __prompt_command and PROMPT_COMMAND for function-existence tests
    if ! type -t __prompt_command &>/dev/null; then
        __prompt_command() { :; }
        PROMPT_COMMAND="__prompt_command"
    fi
fi

# Mock secrets file — maps op:// refs to return values
export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << 'EOF'
op://Homelab/test-cluster/access-key=AKIAIOSFODNN7EXAMPLE
op://Homelab/test-cluster/secret-key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
op://Homelab/test-cluster/kubeconfig=YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6IFtdCg==
op://Homelab/aap/host=https://controller.example.com
op://Homelab/aap/password=s3cret
op://Homelab/aap/username=admin
op://Homelab/test-cluster/token=sha256~fake-token-12345
op://Homelab/test-cluster/api-host=https://api.test-cluster.example.com:6443
op://Homelab/test-registry/username=robot+devenv
op://Homelab/test-registry/password=hunter2
EOF

# Mock op call log for verifying invocations
export MOCK_OP_LOG="$TESTDIR/op-calls.log"

# Test env files
mkdir -p "$TESTDIR/envs"
cat > "$TESTDIR/envs/simple.env" << 'EOF'
AWS_ACCESS_KEY_ID=op://Homelab/test-cluster/access-key
AWS_SECRET_ACCESS_KEY=op://Homelab/test-cluster/secret-key
AWS_DEFAULT_REGION=us-east-1
EOF

cat > "$TESTDIR/envs/with-kubeconfig.env" << 'EOF'
KUBECONFIG_DATA=op://Homelab/test-cluster/kubeconfig
AWS_ACCESS_KEY_ID=op://Homelab/test-cluster/access-key
AWS_DEFAULT_REGION=us-east-1
EOF

cat > "$TESTDIR/envs/other-kubeconfig.env" << 'EOF'
KUBECONFIG_DATA=op://Homelab/test-cluster/kubeconfig
AWS_DEFAULT_REGION=eu-west-1
EOF

cat > "$TESTDIR/envs/token-kubeconfig.env" << 'EOF'
KUBECONFIG_TOKEN=op://Homelab/test-cluster/token
KUBECONFIG_HOST=op://Homelab/test-cluster/api-host
AWS_DEFAULT_REGION=us-west-2
EOF

cat > "$TESTDIR/envs/conflict.env" << 'EOF'
KUBECONFIG_DATA=op://Homelab/test-cluster/kubeconfig
KUBECONFIG_TOKEN=op://Homelab/test-cluster/token
KUBECONFIG_HOST=op://Homelab/test-cluster/api-host
EOF

cat > "$TESTDIR/envs/token-only.env" << 'EOF'
KUBECONFIG_TOKEN=op://Homelab/test-cluster/token
EOF

cat > "$TESTDIR/envs/aap.env" << 'EOF'
CONTROLLER_HOST=op://Homelab/aap/host
CONTROLLER_PASSWORD=op://Homelab/aap/password
CONTROLLER_USERNAME=op://Homelab/aap/username
EOF

cat > "$TESTDIR/envs/registry.env" << 'EOF'
REGISTRY_HOST=registry.example.com
REGISTRY_USERNAME=op://Homelab/test-registry/username
REGISTRY_PASSWORD=op://Homelab/test-registry/password
AWS_DEFAULT_REGION=ap-south-1
EOF

cat > "$TESTDIR/envs/registry-partial.env" << 'EOF'
REGISTRY_HOST=registry.example.com
REGISTRY_USERNAME=op://Homelab/test-registry/username
EOF

# Override the envdir used by use() for testing.
# Redefine use() to point at our test envdir instead of the real one.
_original_use=$(declare -f use)
# shellcheck disable=SC2001
eval "$(echo "$_original_use" | sed "s|/workspace/igou-devenv/envs|$TESTDIR/envs|g")"

# =========================================================================
#  Tests: Shell function existence
# =========================================================================
echo "==> Testing shell functions..."
if [ -n "$(type -t __prompt_command)" ]; then ok "__prompt_command defined"; else fail "__prompt_command defined"; fi
if echo "$PROMPT_COMMAND" | grep -q __prompt_command; then ok "PROMPT_COMMAND set"; else fail "PROMPT_COMMAND set"; fi
if [ -n "$(type -t use)" ]; then ok "use() defined"; else fail "use() defined"; fi
if [ -n "$(type -t unuse)" ]; then ok "unuse() defined"; else fail "unuse() defined"; fi
if [ -n "$(type -t k8s-unset)" ]; then ok "k8s-unset() defined"; else fail "k8s-unset() defined"; fi

# =========================================================================
#  Tests: use() — missing env
# =========================================================================
echo ""
echo "==> Testing use() with missing env..."
if use nonexistent 2>&1 | grep -q "No env file"; then ok "missing env shows error"; else fail "missing env shows error"; fi

# =========================================================================
#  Tests: use() lists available envs
# =========================================================================
echo ""
echo "==> Testing use() lists available envs..."
if compgen -G "/workspace/igou-devenv/envs/*.env" > /dev/null 2>&1; then
    ok "env files listable"
else
    fail "env files listable"
fi

# =========================================================================
#  Tests: use() — simple env (no kubeconfig)
# =========================================================================
echo ""
echo "==> Testing use() — simple env..."

# Clean state
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION OP_ENV OP_ENV_LIST 2>/dev/null || true

use simple > /dev/null 2>&1
if [ "${AWS_ACCESS_KEY_ID:-}" = "AKIAIOSFODNN7EXAMPLE" ]; then
    ok "simple env resolves op:// secrets"
else
    fail "simple env resolves op:// secrets (got: ${AWS_ACCESS_KEY_ID:-unset})"
fi
if [ "${AWS_DEFAULT_REGION:-}" = "us-east-1" ]; then
    ok "simple env passes plain values"
else
    fail "simple env passes plain values (got: ${AWS_DEFAULT_REGION:-unset})"
fi
if [ "${OP_ENV:-}" = "simple" ]; then
    ok "OP_ENV set to env name"
else
    fail "OP_ENV set to env name (got: ${OP_ENV:-unset})"
fi

# =========================================================================
#  Tests: unuse() — simple env
# =========================================================================
echo ""
echo "==> Testing unuse() — simple env..."

unuse simple > /dev/null 2>&1
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    ok "unuse clears exported vars"
else
    fail "unuse clears exported vars (still: ${AWS_ACCESS_KEY_ID:-})"
fi
if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
    ok "unuse clears plain vars"
else
    fail "unuse clears plain vars (still: ${AWS_DEFAULT_REGION:-})"
fi
if [ -z "${OP_ENV:-}" ]; then
    ok "unuse clears OP_ENV"
else
    fail "unuse clears OP_ENV (still: ${OP_ENV:-})"
fi
if [ -z "${OP_ENV_LIST:-}" ]; then
    ok "unuse clears OP_ENV_LIST"
else
    fail "unuse clears OP_ENV_LIST (still: ${OP_ENV_LIST:-})"
fi

# =========================================================================
#  Tests: use() — env with KUBECONFIG_DATA
# =========================================================================
echo ""
echo "==> Testing use() — kubeconfig env..."

unset KUBECONFIG AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION OP_ENV OP_ENV_LIST 2>/dev/null || true

use with-kubeconfig > /dev/null 2>&1
if [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
    ok "kubeconfig temp file created"
else
    fail "kubeconfig temp file created (KUBECONFIG=${KUBECONFIG:-unset})"
fi
if [ -n "${KUBECONFIG:-}" ] && grep -q "apiVersion" "$KUBECONFIG" 2>/dev/null; then
    ok "kubeconfig decoded correctly"
else
    fail "kubeconfig decoded correctly"
fi
if [ "${AWS_ACCESS_KEY_ID:-}" = "AKIAIOSFODNN7EXAMPLE" ]; then
    ok "kubeconfig env also resolves other vars"
else
    fail "kubeconfig env also resolves other vars"
fi

# Save kubeconfig path for cleanup test
_saved_kubeconfig="$KUBECONFIG"

# =========================================================================
#  Tests: unuse() — kubeconfig env cleans up temp file
# =========================================================================
echo ""
echo "==> Testing unuse() — kubeconfig cleanup..."

unuse with-kubeconfig > /dev/null 2>&1
if [ -z "${KUBECONFIG:-}" ]; then
    ok "unuse clears KUBECONFIG"
else
    fail "unuse clears KUBECONFIG (still: ${KUBECONFIG:-})"
fi
if [ ! -f "$_saved_kubeconfig" ]; then
    ok "unuse deletes temp kubeconfig file"
else
    fail "unuse deletes temp kubeconfig file (still exists: $_saved_kubeconfig)"
fi

# =========================================================================
#  Tests: use() — env with KUBECONFIG_TOKEN + KUBECONFIG_HOST
# =========================================================================
echo ""
echo "==> Testing use() — token-based kubeconfig..."

unset KUBECONFIG AWS_DEFAULT_REGION OP_ENV OP_ENV_LIST 2>/dev/null || true

use token-kubeconfig > /dev/null 2>&1
if [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
    ok "token kubeconfig temp file created"
else
    fail "token kubeconfig temp file created (KUBECONFIG=${KUBECONFIG:-unset})"
fi
if [ -n "${KUBECONFIG:-}" ] && grep -q "sha256~fake-token-12345" "$KUBECONFIG" 2>/dev/null; then
    ok "token written into kubeconfig"
else
    fail "token written into kubeconfig"
fi
if [ -n "${KUBECONFIG:-}" ] && grep -q "https://api.test-cluster.example.com:6443" "$KUBECONFIG" 2>/dev/null; then
    ok "host written into kubeconfig"
else
    fail "host written into kubeconfig"
fi
if [ -n "${KUBECONFIG:-}" ] && grep -q "insecure-skip-tls-verify: true" "$KUBECONFIG" 2>/dev/null; then
    ok "kubeconfig has insecure-skip-tls-verify"
else
    fail "kubeconfig has insecure-skip-tls-verify"
fi
if [ "${AWS_DEFAULT_REGION:-}" = "us-west-2" ]; then
    ok "token kubeconfig env also resolves other vars"
else
    fail "token kubeconfig env also resolves other vars (got: ${AWS_DEFAULT_REGION:-unset})"
fi

_saved_token_kubeconfig="$KUBECONFIG"
unuse token-kubeconfig > /dev/null 2>&1
if [ ! -f "$_saved_token_kubeconfig" ]; then
    ok "unuse deletes token kubeconfig temp file"
else
    fail "unuse deletes token kubeconfig temp file"
fi

# =========================================================================
#  Tests: use() — KUBECONFIG_DATA + KUBECONFIG_TOKEN conflict
# =========================================================================
echo ""
echo "==> Testing use() — kubeconfig conflict detection..."

unset KUBECONFIG OP_ENV OP_ENV_LIST 2>/dev/null || true

output=$(use conflict 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -q "both KUBECONFIG_DATA and KUBECONFIG_TOKEN"; then
    ok "conflict between DATA and TOKEN rejected"
else
    fail "conflict between DATA and TOKEN rejected (rc=$rc output: $output)"
fi

# =========================================================================
#  Tests: use() — KUBECONFIG_TOKEN without KUBECONFIG_HOST
# =========================================================================
echo ""
echo "==> Testing use() — token without host rejected..."

output=$(use token-only 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -q "must have both"; then
    ok "token without host rejected"
else
    fail "token without host rejected (rc=$rc output: $output)"
fi

# =========================================================================
#  Tests: use() — env with REGISTRY_HOST/USERNAME/PASSWORD
# =========================================================================
echo ""
echo "==> Testing use() — container registry env..."

unset REGISTRY_AUTH_FILE DOCKER_CONFIG AWS_DEFAULT_REGION OP_ENV OP_ENV_LIST 2>/dev/null || true

use registry > /dev/null 2>&1
if [ -n "${REGISTRY_AUTH_FILE:-}" ] && [ -f "$REGISTRY_AUTH_FILE" ]; then
    ok "registry auth file created"
else
    fail "registry auth file created (REGISTRY_AUTH_FILE=${REGISTRY_AUTH_FILE:-unset})"
fi
if [ "${DOCKER_CONFIG:-}" = "$(dirname "${REGISTRY_AUTH_FILE:-/nonexistent}")" ] && [ -f "${DOCKER_CONFIG:-/nonexistent}/config.json" ]; then
    ok "DOCKER_CONFIG points at the auth file's directory"
else
    fail "DOCKER_CONFIG points at the auth file's directory (DOCKER_CONFIG=${DOCKER_CONFIG:-unset})"
fi
_expected_auth=$(printf '%s:%s' "robot+devenv" "hunter2" | base64 -w0)
if grep -q "\"registry.example.com\"" "${REGISTRY_AUTH_FILE:-/nonexistent}" 2>/dev/null && \
   grep -q "$_expected_auth" "${REGISTRY_AUTH_FILE:-/nonexistent}" 2>/dev/null; then
    ok "auth file has host entry with base64(user:pass)"
else
    fail "auth file has host entry with base64(user:pass)"
fi
if [ "$(stat -c %a "${REGISTRY_AUTH_FILE:-/nonexistent}" 2>/dev/null)" = "600" ]; then
    ok "auth file is mode 600"
else
    fail "auth file is mode 600 (got: $(stat -c %a "${REGISTRY_AUTH_FILE:-/nonexistent}" 2>/dev/null))"
fi
if [ "${AWS_DEFAULT_REGION:-}" = "ap-south-1" ]; then
    ok "registry env also resolves other vars"
else
    fail "registry env also resolves other vars (got: ${AWS_DEFAULT_REGION:-unset})"
fi

# Re-using replaces the previous temp auth dir instead of leaking it
_first_auth_dir="${DOCKER_CONFIG:-}"
use registry > /dev/null 2>&1
if [ ! -d "$_first_auth_dir" ] && [ -f "${REGISTRY_AUTH_FILE:-/nonexistent}" ]; then
    ok "re-use replaces previous auth dir"
else
    fail "re-use replaces previous auth dir (old: $_first_auth_dir)"
fi

_saved_auth_dir="${DOCKER_CONFIG:-}"
unuse registry > /dev/null 2>&1
if [ -z "${REGISTRY_AUTH_FILE:-}" ] && [ -z "${DOCKER_CONFIG:-}" ]; then
    ok "unuse clears REGISTRY_AUTH_FILE and DOCKER_CONFIG"
else
    fail "unuse clears REGISTRY_AUTH_FILE and DOCKER_CONFIG (still: ${REGISTRY_AUTH_FILE:-}/${DOCKER_CONFIG:-})"
fi
if [ ! -d "$_saved_auth_dir" ]; then
    ok "unuse deletes temp auth dir"
else
    fail "unuse deletes temp auth dir (still exists: $_saved_auth_dir)"
fi

# =========================================================================
#  Tests: use() — partial REGISTRY_* keys rejected
# =========================================================================
echo ""
echo "==> Testing use() — partial registry keys rejected..."

output=$(use registry-partial 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -q "must have all of REGISTRY_HOST"; then
    ok "partial registry keys rejected"
else
    fail "partial registry keys rejected (rc=$rc output: $output)"
fi

# =========================================================================
#  Tests: registry EXIT-trap cleanup is owner-scoped (issue #98)
# =========================================================================
echo ""
echo "==> Testing owner-scoped EXIT cleanup — registry auth dir..."

unset OP_ENV OP_ENV_LIST 2>/dev/null || true

use registry > /dev/null 2>&1
_owned_auth_dir="${DOCKER_CONFIG:-}"

if [ "${_USE_TMPAUTH_OWNER_registry:-}" = "$BASHPID" ]; then
    ok "owner PID recorded for created auth dir"
else
    fail "owner PID recorded (got: ${_USE_TMPAUTH_OWNER_registry:-unset}, BASHPID=$BASHPID)"
fi

( _use_cleanup_all ) # subshell → distinct $BASHPID, inherits exported vars
if [ -d "$_owned_auth_dir" ]; then
    ok "child-shell EXIT does not delete sibling auth dir"
else
    fail "child-shell EXIT deleted sibling auth dir ($_owned_auth_dir)"
fi

_use_cleanup_all
if [ ! -d "$_owned_auth_dir" ]; then
    ok "owner-shell EXIT deletes its own auth dir"
else
    fail "owner-shell EXIT deletes its own auth dir ($_owned_auth_dir)"
fi
unuse registry > /dev/null 2>&1

# =========================================================================
#  Tests: use() idempotent — calling twice doesn't error
# =========================================================================
echo ""
echo "==> Testing use() idempotency..."

unset OP_ENV OP_ENV_LIST 2>/dev/null || true

use simple > /dev/null 2>&1
local_rc1=$?
use simple > /dev/null 2>&1
local_rc2=$?
if [ $local_rc1 -eq 0 ] && [ $local_rc2 -eq 0 ]; then
    ok "use same env twice succeeds"
else
    fail "use same env twice succeeds (rc1=$local_rc1 rc2=$local_rc2)"
fi
# OP_ENV_LIST should contain simple only once
if [ "${OP_ENV_LIST:-}" = "simple" ]; then
    ok "OP_ENV_LIST not duplicated"
else
    fail "OP_ENV_LIST not duplicated (got: ${OP_ENV_LIST:-unset})"
fi
unuse > /dev/null 2>&1

# =========================================================================
#  Tests: unuse() idempotent — calling when not active is a no-op
# =========================================================================
echo ""
echo "==> Testing unuse() idempotency..."

unset OP_ENV OP_ENV_LIST 2>/dev/null || true
unuse simple > /dev/null 2>&1
local_rc=$?
if [ $local_rc -eq 0 ]; then
    ok "unuse inactive env is no-op"
else
    fail "unuse inactive env is no-op (rc=$local_rc)"
fi

# =========================================================================
#  Tests: Stacking environments
# =========================================================================
echo ""
echo "==> Testing environment stacking..."

unset OP_ENV OP_ENV_LIST AWS_ACCESS_KEY_ID CONTROLLER_HOST 2>/dev/null || true

use simple > /dev/null 2>&1
use aap > /dev/null 2>&1

if [ "${AWS_ACCESS_KEY_ID:-}" = "AKIAIOSFODNN7EXAMPLE" ]; then
    ok "stacking: first env vars still set"
else
    fail "stacking: first env vars still set (got: ${AWS_ACCESS_KEY_ID:-unset})"
fi
if [ "${CONTROLLER_HOST:-}" = "https://controller.example.com" ]; then
    ok "stacking: second env vars set"
else
    fail "stacking: second env vars set (got: ${CONTROLLER_HOST:-unset})"
fi
if [ "${OP_ENV:-}" = "aap" ]; then
    ok "stacking: OP_ENV shows last-used env"
else
    fail "stacking: OP_ENV shows last-used env (got: ${OP_ENV:-unset})"
fi

# =========================================================================
#  Tests: unuse one stacked env preserves the other
# =========================================================================
echo ""
echo "==> Testing selective unuse..."

unuse aap > /dev/null 2>&1
if [ -z "${CONTROLLER_HOST:-}" ]; then
    ok "unuse aap clears aap vars"
else
    fail "unuse aap clears aap vars (still: ${CONTROLLER_HOST:-})"
fi
if [ "${AWS_ACCESS_KEY_ID:-}" = "AKIAIOSFODNN7EXAMPLE" ]; then
    ok "unuse aap preserves simple vars"
else
    fail "unuse aap preserves simple vars (got: ${AWS_ACCESS_KEY_ID:-unset})"
fi
if [ "${OP_ENV:-}" = "simple" ]; then
    ok "OP_ENV falls back to remaining env"
else
    fail "OP_ENV falls back to remaining env (got: ${OP_ENV:-unset})"
fi

unuse > /dev/null 2>&1

# =========================================================================
#  Tests: unuse with no args clears everything
# =========================================================================
echo ""
echo "==> Testing unuse (no args) clears all..."

use simple > /dev/null 2>&1
use aap > /dev/null 2>&1
unuse > /dev/null 2>&1

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${CONTROLLER_HOST:-}" ]; then
    ok "unuse (no args) clears all vars"
else
    fail "unuse (no args) clears all vars"
fi
if [ -z "${OP_ENV:-}" ] && [ -z "${OP_ENV_LIST:-}" ]; then
    ok "unuse (no args) clears OP_ENV and OP_ENV_LIST"
else
    fail "unuse (no args) clears OP_ENV and OP_ENV_LIST"
fi

# =========================================================================
#  Tests: EXIT-trap cleanup is owner-scoped (issue #98)
# =========================================================================
# A short-lived child interactive shell inherits exported _USE_TMPKUBE_* vars.
# It must NOT delete a kubeconfig created by a different (parent/sibling) shell.
# _use_cleanup_all deletes only files whose _USE_TMPKUBE_OWNER_<name> == $BASHPID.
echo ""
echo "==> Testing owner-scoped EXIT cleanup (issue #98)..."

unset KUBECONFIG OP_ENV OP_ENV_LIST 2>/dev/null || true

use with-kubeconfig > /dev/null 2>&1
_owned_kube="$KUBECONFIG"

# Sanity: owner var was recorded and points at this shell.
if [ "${_USE_TMPKUBE_OWNER_with_kubeconfig:-}" = "$BASHPID" ]; then
    ok "owner PID recorded for created kubeconfig"
else
    fail "owner PID recorded (got: ${_USE_TMPKUBE_OWNER_with_kubeconfig:-unset}, BASHPID=$BASHPID)"
fi

# Simulate a child interactive shell exiting: same inherited env, different
# BASHPID. _use_cleanup_all must NOT delete the parent's file.
( _use_cleanup_all ) # subshell → distinct $BASHPID, inherits exported vars
if [ -f "$_owned_kube" ]; then
    ok "child-shell EXIT does not delete sibling kubeconfig"
else
    fail "child-shell EXIT deleted sibling kubeconfig ($_owned_kube)"
fi
# KUBECONFIG still usable in this (owner) shell.
if [ -f "$KUBECONFIG" ] && grep -q "apiVersion" "$KUBECONFIG" 2>/dev/null; then
    ok "owner shell kubeconfig still valid after child exit"
else
    fail "owner shell kubeconfig still valid after child exit"
fi

# The owning shell's own cleanup DOES delete the file.
_use_cleanup_all
if [ ! -f "$_owned_kube" ]; then
    ok "owner-shell EXIT deletes its own kubeconfig"
else
    fail "owner-shell EXIT deletes its own kubeconfig ($_owned_kube)"
fi
unuse with-kubeconfig > /dev/null 2>&1

# =========================================================================
#  Tests: k8s-unset
# =========================================================================
echo ""
echo "==> Testing k8s-unset..."
export KUBECONFIG=/tmp/fake K8S_AUTH_HOST=fake K8S_AUTH_API_KEY=fake
k8s-unset > /dev/null
if [ -z "${KUBECONFIG:-}" ] && [ -z "${K8S_AUTH_HOST:-}" ] && [ -z "${K8S_AUTH_API_KEY:-}" ]; then
    ok "k8s-unset clears vars"
else
    fail "k8s-unset clears vars"
fi

# =========================================================================
#  Tests: mock op call log
# =========================================================================
echo ""
echo "==> Verifying op invocations..."
if grep -q "op read op://Homelab/test-cluster/kubeconfig" "$MOCK_OP_LOG"; then
    ok "op read called for kubeconfig"
else
    fail "op read called for kubeconfig"
fi
if grep -q "op inject" "$MOCK_OP_LOG"; then
    ok "op inject called to resolve secrets"
else
    fail "op inject called to resolve secrets"
fi

# =========================================================================
#  Results
# =========================================================================
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
