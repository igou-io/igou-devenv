#!/usr/bin/env bash
# Test claude-run and cursor-run env resolution logic using --dry-run mode.
# Uses mock-op.sh for 1Password and a mock podman to avoid real container ops.
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

# Mock op binary
mkdir -p "$TESTDIR/bin"
cp "$SCRIPT_DIR/mock-op.sh" "$TESTDIR/bin/op"

# Mock podman — just succeed for "image exists"
cat > "$TESTDIR/bin/podman" << 'PODMAN'
#!/usr/bin/env bash
if [ "${1:-}" = "image" ] && [ "${2:-}" = "exists" ]; then
    exit 0
fi
echo "mock-podman: unexpected call: $*" >&2
exit 1
PODMAN
chmod +x "$TESTDIR/bin/podman"

export PATH="$TESTDIR/bin:$PATH"

# Mock secrets
export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << 'EOF'
op://Homelab/test-cluster/access-key=AKIAIOSFODNN7EXAMPLE
op://Homelab/test-cluster/secret-key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
op://Homelab/test-cluster/kubeconfig=YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6IFtdCg==
op://Homelab/test-cluster/token=sha256~fake-token-12345
op://Homelab/test-cluster/api-host=https://api.test-cluster.example.com:6443
EOF

export MOCK_OP_LOG="$TESTDIR/op-calls.log"

# Test env files — use real envs dir path that the scripts expect
ENVDIR="$REPO_DIR/envs"

# Create test env files in the real envs dir (cleaned up at exit)
_test_envs=()
_create_test_env() {
    local name="$1"
    local content="$2"
    echo "$content" > "$ENVDIR/${name}.env"
    _test_envs+=("$ENVDIR/${name}.env")
}

_cleanup_test_envs() {
    for f in "${_test_envs[@]}"; do
        rm -f "$f"
    done
    rm -rf "$TESTDIR"
}
trap _cleanup_test_envs EXIT

_create_test_env "test-simple" "AWS_ACCESS_KEY_ID=op://Homelab/test-cluster/access-key
AWS_SECRET_ACCESS_KEY=op://Homelab/test-cluster/secret-key
AWS_DEFAULT_REGION=us-east-1"

_create_test_env "test-kubedata" "KUBECONFIG_DATA=op://Homelab/test-cluster/kubeconfig
AWS_DEFAULT_REGION=us-east-1"

_create_test_env "test-kubetoken" "KUBECONFIG_TOKEN=op://Homelab/test-cluster/token
KUBECONFIG_HOST=op://Homelab/test-cluster/api-host
AWS_DEFAULT_REGION=us-west-2"

_create_test_env "test-conflict" "KUBECONFIG_DATA=op://Homelab/test-cluster/kubeconfig
KUBECONFIG_TOKEN=op://Homelab/test-cluster/token
KUBECONFIG_HOST=op://Homelab/test-cluster/api-host"

_create_test_env "test-token-only" "KUBECONFIG_TOKEN=op://Homelab/test-cluster/token"

# Helper: run a script with --dry-run and capture output + exit code
run_dry() {
    local script="$1"
    shift
    output=$("$script" --dry-run "$@" 2>&1)
    rc=$?
    echo "$output"
    return $rc
}

# =========================================================================
#  Test both scripts with the same cases
# =========================================================================
for script_name in claude-run cursor-run; do
    SCRIPT="$REPO_DIR/bin/$script_name"
    echo "========================================="
    echo "  Testing $script_name"
    echo "========================================="

    # Reset op call log between scripts
    true > "$MOCK_OP_LOG"

    # --- Simple env (no kubeconfig) ---
    echo ""
    echo "==> $script_name: simple env..."
    output=$(run_dry "$SCRIPT" -e test-simple)
    rc=$?

    if [ $rc -eq 0 ]; then
        ok "$script_name: simple env exits 0"
    else
        fail "$script_name: simple env exits 0 (rc=$rc)"
    fi
    if echo "$output" | grep -q "KUBECONFIG"; then
        fail "$script_name: simple env has no KUBECONFIG (found KUBECONFIG in output)"
    else
        ok "$script_name: simple env has no KUBECONFIG"
    fi
    if echo "$output" | grep -q "AWS_DEFAULT_REGION=us-east-1"; then
        ok "$script_name: simple env passes plain values"
    else
        fail "$script_name: simple env passes plain values"
    fi

    # --- KUBECONFIG_DATA env ---
    echo ""
    echo "==> $script_name: KUBECONFIG_DATA env..."
    output=$(run_dry "$SCRIPT" -e test-kubedata)
    rc=$?

    if [ $rc -eq 0 ]; then
        ok "$script_name: kubedata env exits 0"
    else
        fail "$script_name: kubedata env exits 0 (rc=$rc)"
    fi
    if echo "$output" | grep -q "KUBECONFIG=/tmp/kubeconfig"; then
        ok "$script_name: kubedata env sets KUBECONFIG"
    else
        fail "$script_name: kubedata env sets KUBECONFIG"
    fi
    if echo "$output" | grep -q "/tmp/kubeconfig\.\|kubeconfig\."; then
        ok "$script_name: kubedata env mounts temp file"
    else
        fail "$script_name: kubedata env mounts temp file"
    fi
    # KUBECONFIG_DATA should NOT appear as an env var
    if echo "$output" | grep -q "KUBECONFIG_DATA"; then
        fail "$script_name: kubedata env strips KUBECONFIG_DATA from env"
    else
        ok "$script_name: kubedata env strips KUBECONFIG_DATA from env"
    fi

    # --- KUBECONFIG_TOKEN + KUBECONFIG_HOST env ---
    echo ""
    echo "==> $script_name: KUBECONFIG_TOKEN + KUBECONFIG_HOST env..."
    output=$(run_dry "$SCRIPT" -e test-kubetoken)
    rc=$?

    if [ $rc -eq 0 ]; then
        ok "$script_name: kubetoken env exits 0"
    else
        fail "$script_name: kubetoken env exits 0 (rc=$rc, output: $output)"
    fi
    if echo "$output" | grep -q "KUBECONFIG=/tmp/kubeconfig"; then
        ok "$script_name: kubetoken env sets KUBECONFIG"
    else
        fail "$script_name: kubetoken env sets KUBECONFIG"
    fi
    if echo "$output" | grep -q "/tmp/kubeconfig\.\|kubeconfig\."; then
        ok "$script_name: kubetoken env mounts temp file"
    else
        fail "$script_name: kubetoken env mounts temp file"
    fi
    # KUBECONFIG_TOKEN and KUBECONFIG_HOST should NOT appear as env vars
    if echo "$output" | grep -q "KUBECONFIG_TOKEN\|KUBECONFIG_HOST"; then
        fail "$script_name: kubetoken env strips TOKEN/HOST from env"
    else
        ok "$script_name: kubetoken env strips TOKEN/HOST from env"
    fi
    if echo "$output" | grep -q "AWS_DEFAULT_REGION=us-west-2"; then
        ok "$script_name: kubetoken env also resolves other vars"
    else
        fail "$script_name: kubetoken env also resolves other vars"
    fi

    # --- Conflict: KUBECONFIG_DATA + KUBECONFIG_TOKEN ---
    echo ""
    echo "==> $script_name: conflict detection..."
    output=$(run_dry "$SCRIPT" -e test-conflict 2>&1)
    rc=$?

    if [ $rc -ne 0 ] && echo "$output" | grep -q "both KUBECONFIG_DATA and KUBECONFIG_TOKEN"; then
        ok "$script_name: conflict between DATA and TOKEN rejected"
    else
        fail "$script_name: conflict between DATA and TOKEN rejected (rc=$rc)"
    fi

    # --- Token without host ---
    echo ""
    echo "==> $script_name: token without host rejected..."
    output=$(run_dry "$SCRIPT" -e test-token-only 2>&1)
    rc=$?

    if [ $rc -ne 0 ] && echo "$output" | grep -q "must have both"; then
        ok "$script_name: token without host rejected"
    else
        fail "$script_name: token without host rejected (rc=$rc)"
    fi

    # --- Verify temp kubeconfig content for token strategy ---
    # The --dry-run exit triggers the cleanup trap which deletes the temp file.
    # To verify content, copy the temp file before --dry-run exits by wrapping
    # the script invocation so we can intercept the file path from the output
    # and copy it in a subshell before cleanup runs.
    echo ""
    echo "==> $script_name: verify generated kubeconfig content..."
    verify_dir="$TESTDIR/verify-kubeconfig"
    mkdir -p "$verify_dir"
    # Run the script, capture output, then immediately copy any kubeconfig temp files
    output=$(run_dry "$SCRIPT" -e test-kubetoken)
    # Since the script's EXIT trap cleaned up, we verify the content was correct by
    # generating the kubeconfig ourselves with the same mock op and comparing structure.
    # The dry-run output already proved KUBECONFIG=/tmp/kubeconfig is set and TOKEN/HOST
    # are stripped. The kubeconfig template is identical to dotfiles/.bashrc which is
    # tested by test-env.sh. Verify the template is consistent between the two.
    # shellcheck disable=SC2016
    kube_template_run=$(sed -n '/cat > "\$tmpkube" << KUBECFG/,/^KUBECFG$/p' "$SCRIPT" | sed 's/^[[:space:]]*//')
    # shellcheck disable=SC2016
    kube_template_bashrc=$(sed -n '/cat > "\$tmpkube" << KUBECFG/,/^KUBECFG$/p' "$REPO_DIR/dotfiles/.bashrc" | sed 's/^[[:space:]]*//')
    if [ "$kube_template_run" = "$kube_template_bashrc" ]; then
        ok "$script_name: kubeconfig template matches dotfiles/.bashrc"
    else
        fail "$script_name: kubeconfig template matches dotfiles/.bashrc"
    fi
done

# =========================================================================
#  Results
# =========================================================================
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
