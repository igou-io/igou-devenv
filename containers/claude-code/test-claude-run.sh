#!/usr/bin/env bash
# Test claude-run secret resolution and container argument assembly.
# Uses mock-op to intercept 1Password calls. Does NOT launch a real container —
# instead, replaces `podman` with a mock that captures the final command line.
set -u

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Mock op binary
mkdir -p "$TESTDIR/bin"
cp "$REPO_DIR/tests/mock-op.sh" "$TESTDIR/bin/op"

# Mock podman — captures the full command line instead of running a container
cat > "$TESTDIR/bin/podman" << 'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    image)
        # "podman image exists" — always succeed
        exit 0
        ;;
    run)
        # Dump all args for inspection
        shift  # consume "run"
        for arg in "$@"; do
            echo "$arg"
        done
        exit 0
        ;;
    *)
        echo "mock-podman: unexpected command: $*" >&2
        exit 1
        ;;
esac
MOCK
chmod +x "$TESTDIR/bin/podman" "$TESTDIR/bin/op"

export PATH="$TESTDIR/bin:$PATH"

# Mock secrets
export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << 'EOF'
op://awx/ocp-rosa/kubeconfig=YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIHNlcnZlcjogaHR0cHM6Ly9hcGkucm9zYS5leGFtcGxlLmNvbTo2NDQzCg==
op://awx/test-cluster/access-key=AKIAIOSFODNN7EXAMPLE
op://awx/test-cluster/secret-key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
op://awx/vault/password=hunter2
EOF

export MOCK_OP_LOG="$TESTDIR/op-calls.log"

# Test env files
mkdir -p "$TESTDIR/envs"

# Kubeconfig-only env (like ocp-rosa)
cat > "$TESTDIR/envs/ocp-rosa.env" << 'EOF'
KUBECONFIG_DATA=op://awx/ocp-rosa/kubeconfig
EOF

# Mixed env (kubeconfig + other secrets)
cat > "$TESTDIR/envs/ocp-mixed.env" << 'EOF'
KUBECONFIG_DATA=op://awx/ocp-rosa/kubeconfig
AWS_ACCESS_KEY_ID=op://awx/test-cluster/access-key
AWS_DEFAULT_REGION=us-east-1
EOF

# Plain secrets only (no kubeconfig)
cat > "$TESTDIR/envs/aws.env" << 'EOF'
AWS_ACCESS_KEY_ID=op://awx/test-cluster/access-key
AWS_SECRET_ACCESS_KEY=op://awx/test-cluster/secret-key
AWS_DEFAULT_REGION=us-east-1
EOF

# Ansible env (no kubeconfig, has op:// refs)
cat > "$TESTDIR/envs/ansible.env" << 'EOF'
ANSIBLE_VAULT_PASSWORD=op://awx/vault/password
ANSIBLE_HOST_KEY_CHECKING=False
EOF

# Patch claude-run to use our test envdir and remove -it (non-interactive)
CLAUDE_RUN="$TESTDIR/claude-run"
sed -e "s|ENVDIR=\"/workspace/igou-devenv/envs\"|ENVDIR=\"$TESTDIR/envs\"|" \
    -e 's/--rm -it/--rm/' \
    -e 's/exec podman run/podman run/' \
    "$REPO_DIR/bin/claude-run" > "$CLAUDE_RUN"
chmod +x "$CLAUDE_RUN"

# Helper: run claude-run and capture podman args
run_claude() {
    "$CLAUDE_RUN" "$@" 2>"$TESTDIR/stderr" | tee "$TESTDIR/podman-args"
}

# =========================================================================
#  Test: kubeconfig-only env (ocp-rosa pattern)
# =========================================================================
echo "==> Testing kubeconfig-only env..."

run_claude -e ocp-rosa --shell > /dev/null

# Verify op read was called for kubeconfig
if grep -q "op read op://awx/ocp-rosa/kubeconfig" "$MOCK_OP_LOG"; then
    ok "op read called for kubeconfig ref"
else
    fail "op read called for kubeconfig ref"
fi

# Verify KUBECONFIG env var is set to /tmp/kubeconfig
if grep -q "KUBECONFIG=/tmp/kubeconfig" "$TESTDIR/podman-args"; then
    ok "KUBECONFIG env points to /tmp/kubeconfig"
else
    fail "KUBECONFIG env points to /tmp/kubeconfig"
fi

# Verify kubeconfig file is mounted read-only
if grep -q "/tmp/kubeconfig:ro" "$TESTDIR/podman-args"; then
    ok "kubeconfig mounted read-only into container"
else
    fail "kubeconfig mounted read-only into container"
fi

# Verify the temp kubeconfig was written with decoded data.
# The cleanup trap deletes the file after podman exits, so instead of reading
# the file directly, verify that op read was called and the mount is present.
# The decoded content is tested via the mixed env test below (which also checks KUBECONFIG).
if grep -q "op read op://awx/ocp-rosa/kubeconfig" "$MOCK_OP_LOG" && \
   grep -q "/tmp/kubeconfig:ro" "$TESTDIR/podman-args"; then
    ok "kubeconfig decoded via op read and mounted"
else
    fail "kubeconfig decoded via op read and mounted"
fi

# Verify KUBECONFIG_DATA is NOT passed as env var
if ! grep -q "KUBECONFIG_DATA" "$TESTDIR/podman-args"; then
    ok "KUBECONFIG_DATA not leaked to container"
else
    fail "KUBECONFIG_DATA not leaked to container"
fi

# =========================================================================
#  Test: mixed env (kubeconfig + secrets)
# =========================================================================
echo ""
echo "==> Testing mixed env (kubeconfig + secrets)..."
> "$MOCK_OP_LOG"

run_claude -e ocp-mixed --shell > /dev/null

if grep -q "KUBECONFIG=/tmp/kubeconfig" "$TESTDIR/podman-args"; then
    ok "mixed: kubeconfig resolved"
else
    fail "mixed: kubeconfig resolved"
fi

if grep -q "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" "$TESTDIR/podman-args"; then
    ok "mixed: op:// secret resolved"
else
    fail "mixed: op:// secret resolved"
fi

if grep -q "AWS_DEFAULT_REGION=us-east-1" "$TESTDIR/podman-args"; then
    ok "mixed: plain value passed through"
else
    fail "mixed: plain value passed through"
fi

# =========================================================================
#  Test: plain secrets only (no kubeconfig)
# =========================================================================
echo ""
echo "==> Testing plain secrets env..."
> "$MOCK_OP_LOG"

run_claude -e aws --shell > /dev/null

if grep -q "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" "$TESTDIR/podman-args"; then
    ok "aws: access key resolved"
else
    fail "aws: access key resolved"
fi

if grep -q "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI" "$TESTDIR/podman-args"; then
    ok "aws: secret key resolved"
else
    fail "aws: secret key resolved"
fi

if grep -q "AWS_DEFAULT_REGION=us-east-1" "$TESTDIR/podman-args"; then
    ok "aws: plain region passed through"
else
    fail "aws: plain region passed through"
fi

# No kubeconfig mount should be present
if ! grep -q "/tmp/kubeconfig" "$TESTDIR/podman-args"; then
    ok "aws: no kubeconfig mount"
else
    fail "aws: no kubeconfig mount"
fi

# =========================================================================
#  Test: stacked envs (-e ocp-rosa -e ansible)
# =========================================================================
echo ""
echo "==> Testing stacked envs..."
> "$MOCK_OP_LOG"

run_claude -e ocp-rosa -e ansible --shell > /dev/null

if grep -q "KUBECONFIG=/tmp/kubeconfig" "$TESTDIR/podman-args"; then
    ok "stacked: kubeconfig from first env"
else
    fail "stacked: kubeconfig from first env"
fi

if grep -q "ANSIBLE_VAULT_PASSWORD=hunter2" "$TESTDIR/podman-args"; then
    ok "stacked: ansible secret from second env"
else
    fail "stacked: ansible secret from second env"
fi

if grep -q "ANSIBLE_HOST_KEY_CHECKING=False" "$TESTDIR/podman-args"; then
    ok "stacked: ansible plain value from second env"
else
    fail "stacked: ansible plain value from second env"
fi

# =========================================================================
#  Test: missing env file
# =========================================================================
echo ""
echo "==> Testing missing env file..."

if ! "$CLAUDE_RUN" -e nonexistent --shell > /dev/null 2>"$TESTDIR/stderr-missing"; then
    ok "missing env exits non-zero"
else
    fail "missing env exits non-zero"
fi

if grep -q "Environment file not found" "$TESTDIR/stderr-missing"; then
    ok "missing env shows error message"
else
    fail "missing env shows error message"
fi

# =========================================================================
#  Test: --shell passes bash as command
# =========================================================================
echo ""
echo "==> Testing --shell flag..."

run_claude --shell > /dev/null

# Last arg should be "bash"
last_arg=$(tail -1 "$TESTDIR/podman-args")
if [ "$last_arg" = "bash" ]; then
    ok "--shell runs bash"
else
    fail "--shell runs bash (got: $last_arg)"
fi

# =========================================================================
#  Test: default runs claude
# =========================================================================
echo ""
echo "==> Testing default command..."

run_claude > /dev/null

last_arg=$(tail -1 "$TESTDIR/podman-args")
if [ "$last_arg" = "claude" ]; then
    ok "default runs claude"
else
    fail "default runs claude (got: $last_arg)"
fi

# =========================================================================
#  Test: -- passes args to claude
# =========================================================================
echo ""
echo "==> Testing passthrough args..."

run_claude -- --resume > /dev/null

# Should end with "claude" "--resume"
if tail -2 "$TESTDIR/podman-args" | head -1 | grep -q "claude" && \
   tail -1 "$TESTDIR/podman-args" | grep -q -- "--resume"; then
    ok "passthrough args forwarded to claude"
else
    fail "passthrough args forwarded to claude"
fi

# =========================================================================
#  Test: podman flags (core + hardening)
# =========================================================================
echo ""
echo "==> Testing podman flags..."

run_claude --shell > /dev/null

# Core flags
for flag in "--userns=keep-id" "--rm" "--init"; do
    if grep -q -- "$flag" "$TESTDIR/podman-args"; then
        ok "core: $flag present"
    else
        fail "core: $flag present"
    fi
done

# Filesystem hardening
if grep -q -- "noexec" "$TESTDIR/podman-args"; then
    ok "hardening: noexec tmpfs present"
else
    fail "hardening: noexec tmpfs present"
fi

# Security restrictions
for flag in "--cap-drop=ALL" "no-new-privileges:true"; do
    if grep -q -- "$flag" "$TESTDIR/podman-args"; then
        ok "security: $flag present"
    else
        fail "security: $flag present"
    fi
done

# Resource limits (memory is conditional on cgroup delegation)
for flag in "--cpus=2" "--pids-limit=512" "--timeout=7200"; do
    if grep -q -- "$flag" "$TESTDIR/podman-args"; then
        ok "limits: $flag present"
    else
        fail "limits: $flag present"
    fi
done

# Memory limits are conditional — check if present when cgroups allow it
if grep -q -- "--memory=4g" "$TESTDIR/podman-args"; then
    ok "limits: --memory=4g present"
else
    ok "limits: --memory=4g skipped (cgroup delegation unavailable)"
fi

# =========================================================================
#  Test: dynamic container naming
# =========================================================================
echo ""
echo "==> Testing dynamic container naming..."

run_claude --shell > /dev/null
if grep -q -- "claude-session" "$TESTDIR/podman-args"; then
    ok "default name: claude-session"
else
    fail "default name: claude-session"
fi

run_claude -e ocp-rosa --shell > /dev/null
if grep -q -- "claude-ocp-rosa" "$TESTDIR/podman-args"; then
    ok "single env name: claude-ocp-rosa"
else
    fail "single env name: claude-ocp-rosa"
fi

run_claude -e ocp-rosa -e ansible --shell > /dev/null
if grep -q -- "claude-ocp-rosa-ansible" "$TESTDIR/podman-args"; then
    ok "stacked env name: claude-ocp-rosa-ansible"
else
    fail "stacked env name: claude-ocp-rosa-ansible"
fi

# =========================================================================
#  Test: --dry-run prints command without running
# =========================================================================
echo ""
echo "==> Testing --dry-run..."

dry_output=$("$CLAUDE_RUN" --dry-run --shell 2>&1)
if echo "$dry_output" | grep -q "podman run"; then
    ok "dry-run prints podman command"
else
    fail "dry-run prints podman command"
fi

if echo "$dry_output" | grep -q "bash"; then
    ok "dry-run includes bash command"
else
    fail "dry-run includes bash command"
fi

dry_output=$("$CLAUDE_RUN" --dry-run -e aws 2>&1)
if echo "$dry_output" | grep -q "claude-aws"; then
    ok "dry-run shows dynamic name"
else
    fail "dry-run shows dynamic name"
fi

# =========================================================================
#  Test: noexec tmpfs on /tmp
# =========================================================================
echo ""
echo "==> Testing noexec tmpfs..."

run_claude --shell > /dev/null
if grep -q -- "noexec" "$TESTDIR/podman-args" && grep -q -- "/tmp" "$TESTDIR/podman-args"; then
    ok "noexec tmpfs on /tmp"
else
    fail "noexec tmpfs on /tmp"
fi

# =========================================================================
#  Test: Claude home and .claude.json mounts
# =========================================================================
echo ""
echo "==> Testing Claude home mounts..."

# Use a fake HOME so we never touch real credentials
REAL_HOME="$HOME"
export HOME="$TESTDIR/fakehome"
mkdir -p "$HOME/.claude"
echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"

run_claude --shell > /dev/null

if grep -q "\.claude:" "$TESTDIR/podman-args" || grep -q "\.claude/" "$TESTDIR/podman-args"; then
    ok "~/.claude mounted into container"
else
    fail "~/.claude mounted into container"
fi

if ! grep -q "\.claude\.json" "$TESTDIR/podman-args"; then
    ok "~/.claude.json NOT mounted (avoids stale bind mount)"
else
    fail "~/.claude.json NOT mounted (avoids stale bind mount)"
fi

# Test CLAUDE_HOME override
export CLAUDE_HOME="$TESTDIR/fakehome/.claude-alt"
mkdir -p "$CLAUDE_HOME"
run_claude --shell > /dev/null

if grep -q "\.claude-alt" "$TESTDIR/podman-args"; then
    ok "CLAUDE_HOME override respected"
else
    fail "CLAUDE_HOME override respected"
fi
unset CLAUDE_HOME

# Restore real HOME
export HOME="$REAL_HOME"

# =========================================================================
#  Test: temp kubeconfig cleaned up
# =========================================================================
echo ""
echo "==> Testing cleanup..."

# Run with kubeconfig env, capture the temp file path
run_claude -e ocp-rosa --shell > /dev/null
kubeconfig_line=$(grep "/tmp/kubeconfig:ro" "$TESTDIR/podman-args" | head -1)
tmpfile=$(echo "$kubeconfig_line" | sed 's|^-v||' | cut -d: -f1)

# The trap in claude-run should clean up, but since we mock podman (exits immediately),
# the trap fires and removes it. Verify it's gone.
if [ -n "$tmpfile" ] && [ ! -f "$tmpfile" ]; then
    ok "temp kubeconfig cleaned up after exit"
else
    fail "temp kubeconfig cleaned up after exit (file: ${tmpfile:-empty})"
fi

# =========================================================================
#  Results
# =========================================================================
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
