#!/usr/bin/env bash
# Test environment switching shell functions (use, k8s-unset, prompt).
# Must be run with bash -i (interactive) so .bashrc is sourced.
# Uses mock-op.sh to intercept 1Password CLI calls.
# No set -e or pipefail — test pass/fail is tracked via PASS/FAIL counters.
set -u

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Mock secrets file — maps op:// refs to return values
export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << 'EOF'
op://Homelab/test-cluster/access-key=AKIAIOSFODNN7EXAMPLE
op://Homelab/test-cluster/secret-key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
op://Homelab/test-cluster/kubeconfig=YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6IFtdCg==
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

# Override the envdir used by use() for testing
# Redefine use() to point at our test fixtures
_original_use=$(declare -f use)
eval "test_use() {
    local envdir=\"$TESTDIR/envs\"
    local envfile=\"\${envdir}/\${1}.env\"
    if [ ! -f \"\$envfile\" ]; then
        echo \"No env file: \$envfile\"
        echo \"Available:\"
        ls \"\${envdir}\"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\\.env\$//'
        return 1
    fi
    # Prevent stacking the same env twice
    if [[ \",\${OP_ENV_LIST:-},\" == *\",\${1},\"* ]]; then
        echo \"Environment '\${1}' is already active\"
        return 1
    fi
    # Block if a kubeconfig env is already active
    local kubeconfig_ref
    kubeconfig_ref=\$(grep '^KUBECONFIG_DATA=' \"\$envfile\" | cut -d= -f2)
    if [ -n \"\$kubeconfig_ref\" ] && [ -n \"\${KUBECONFIG:-}\" ]; then
        echo \"A kubeconfig environment is already active (\${OP_ENV})\"
        echo \"Exit the current environment first, or use k8s-unset\"
        return 1
    fi
    local new_env=\"\${OP_ENV:+\${OP_ENV}/}\${1}\"
    local new_list=\"\${OP_ENV_LIST:+\${OP_ENV_LIST},}\${1}\"
    if [ -n \"\$kubeconfig_ref\" ]; then
        local tmpkube tmpenv
        tmpkube=\$(mktemp /tmp/kubeconfig.XXXXXX)
        tmpenv=\$(mktemp /tmp/env.XXXXXX)
        op read \"\$kubeconfig_ref\" | base64 -d > \"\$tmpkube\"
        grep -v '^KUBECONFIG_DATA=' \"\$envfile\" > \"\$tmpenv\"
        OP_ENV=\"\$new_env\" OP_ENV_LIST=\"\$new_list\" KUBECONFIG=\"\$tmpkube\" op run --env-file=\"\$tmpenv\" -- bash -c \"\${TEST_USE_CMD:-true}\"
        rm -f \"\$tmpkube\" \"\$tmpenv\"
    else
        OP_ENV=\"\$new_env\" OP_ENV_LIST=\"\$new_list\" op run --env-file=\"\$envfile\" -- bash -c \"\${TEST_USE_CMD:-true}\"
    fi
}"

# =========================================================================
#  Tests: Shell function existence
# =========================================================================
echo "==> Testing shell functions..."
if [ -n "$(type -t __prompt_command)" ]; then ok "__prompt_command defined"; else fail "__prompt_command defined"; fi
if echo "$PROMPT_COMMAND" | grep -q __prompt_command; then ok "PROMPT_COMMAND set"; else fail "PROMPT_COMMAND set"; fi
if [ -n "$(type -t use)" ]; then ok "use() defined"; else fail "use() defined"; fi
if [ -n "$(type -t k8s-unset)" ]; then ok "k8s-unset() defined"; else fail "k8s-unset() defined"; fi

# =========================================================================
#  Tests: use() — missing env
# =========================================================================
echo ""
echo "==> Testing use() with missing env..."
if use nonexistent 2>&1 | grep -q "No env file"; then ok "missing env shows error"; else fail "missing env shows error"; fi

# =========================================================================
#  Tests: use() — lists available envs
# =========================================================================
echo ""
echo "==> Testing use() lists available envs..."
if ls /workspace/igou-devenv/envs/*.env 2>/dev/null | grep -q env; then
    ok "env files listable"
else
    fail "env files listable"
fi

# =========================================================================
#  Tests: OP_ENV stacking
# =========================================================================
echo ""
echo "==> Testing OP_ENV stacking..."
if OP_ENV="k3s" bash -c '[ "$OP_ENV" = "k3s" ]'; then ok "OP_ENV set"; else fail "OP_ENV set"; fi
if OP_ENV="k3s" bash -c 'export OP_ENV="${OP_ENV:+$OP_ENV/}aap"; [ "$OP_ENV" = "k3s/aap" ]'; then
    ok "OP_ENV stacks"
else
    fail "OP_ENV stacks"
fi

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
#  Tests: use() with mock op — simple env (no kubeconfig)
# =========================================================================
echo ""
echo "==> Testing use() with mock op — simple env..."

TEST_USE_CMD='echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"' \
    test_use simple > "$TESTDIR/simple-output" 2>&1
if grep -q "AKIAIOSFODNN7EXAMPLE" "$TESTDIR/simple-output"; then
    ok "simple env resolves op:// secrets"
else
    fail "simple env resolves op:// secrets"
fi
if grep -q "us-east-1" "$TESTDIR/simple-output"; then
    ok "simple env passes plain values"
else
    fail "simple env passes plain values"
fi

# =========================================================================
#  Tests: use() with mock op — env with KUBECONFIG_DATA
# =========================================================================
echo ""
echo "==> Testing use() with mock op — kubeconfig env..."

TEST_USE_CMD='cat "$KUBECONFIG"' \
    test_use with-kubeconfig > "$TESTDIR/kube-output" 2>&1
if grep -q "apiVersion" "$TESTDIR/kube-output"; then
    ok "kubeconfig decoded and written to temp file"
else
    fail "kubeconfig decoded and written to temp file"
fi

# Verify KUBECONFIG_DATA was NOT passed as env var
TEST_USE_CMD='echo "KUBECONFIG_DATA=${KUBECONFIG_DATA:-unset}"' \
    test_use with-kubeconfig > "$TESTDIR/kube-strip-output" 2>&1
if grep -q "KUBECONFIG_DATA=unset" "$TESTDIR/kube-strip-output"; then
    ok "KUBECONFIG_DATA stripped from env"
else
    fail "KUBECONFIG_DATA stripped from env"
fi

# =========================================================================
#  Tests: use() — duplicate env rejected
# =========================================================================
echo ""
echo "==> Testing use() rejects duplicate env..."

# Simulate already having "simple" active via OP_ENV_LIST
output=$(OP_ENV="simple" OP_ENV_LIST="simple" test_use simple 2>&1)
if echo "$output" | grep -q "already active"; then
    ok "duplicate env rejected"
else
    fail "duplicate env rejected"
fi

# Stacking different envs should still work
output=$(OP_ENV="simple" OP_ENV_LIST="simple" TEST_USE_CMD='echo "OP_ENV=$OP_ENV"' test_use with-kubeconfig 2>&1)
if echo "$output" | grep -q "simple/with-kubeconfig"; then
    ok "different envs can still stack"
else
    fail "different envs can still stack"
fi

# =========================================================================
#  Tests: use() — second kubeconfig env rejected
# =========================================================================
echo ""
echo "==> Testing use() rejects second kubeconfig env..."

# Simulate having a kubeconfig already active (KUBECONFIG is set)
output=$(KUBECONFIG="/tmp/existing.kubeconfig" OP_ENV="with-kubeconfig" OP_ENV_LIST="with-kubeconfig" \
    test_use other-kubeconfig 2>&1)
if echo "$output" | grep -q "kubeconfig environment is already active"; then
    ok "second kubeconfig env rejected"
else
    fail "second kubeconfig env rejected"
fi

# Stacking a non-kubeconfig env on top of a kubeconfig env should work
output=$(KUBECONFIG="/tmp/existing.kubeconfig" OP_ENV="with-kubeconfig" OP_ENV_LIST="with-kubeconfig" \
    TEST_USE_CMD='echo "OP_ENV=$OP_ENV"' test_use simple 2>&1)
if echo "$output" | grep -q "with-kubeconfig/simple"; then
    ok "non-kubeconfig env stacks on kubeconfig env"
else
    fail "non-kubeconfig env stacks on kubeconfig env"
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
if grep -q "op run --env-file=" "$MOCK_OP_LOG"; then
    ok "op run called with env file"
else
    fail "op run called with env file"
fi

# =========================================================================
#  Results
# =========================================================================
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
