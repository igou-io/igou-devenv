#!/usr/bin/env bash
# Tests bin/opencode-sandbox-launch — the container launcher that backs the
# ADDITIONAL t3 opencode provider instance. Uses mock op + mock podman and
# --dry-run so no real 1Password, image, or container is needed (CI-safe).
set -u

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH="$REPO_DIR/.devcontainer/opencode-sandbox-launch"

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Mock op + a mock podman that only answers `image exists`.
mkdir -p "$TESTDIR/bin"
cp "$SCRIPT_DIR/mock-op.sh" "$TESTDIR/bin/op"
cat > "$TESTDIR/bin/podman" << 'PODMAN'
#!/usr/bin/env bash
[ "${1:-}" = "image" ] && [ "${2:-}" = "exists" ] && exit 0
echo "mock-podman: unexpected call: $*" >&2
exit 1
PODMAN
chmod +x "$TESTDIR/bin/podman"
export PATH="$TESTDIR/bin:$PATH"

export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
cat > "$MOCK_OP_SECRETS_FILE" << 'EOF'
op://awx/ocp/reader-token=sha256~fake-reader-token
op://awx/ocp/api-host=https://api.ocp.igou.systems:6443
EOF

# Isolated env catalog (does not touch the repo's real envs/).
export OPENCODE_SANDBOX_ENVDIR="$TESTDIR/envs"
mkdir -p "$OPENCODE_SANDBOX_ENVDIR"
cat > "$OPENCODE_SANDBOX_ENVDIR/ocp-cluster-reader.env" << 'EOF'
KUBECONFIG_TOKEN=op://awx/ocp/reader-token
KUBECONFIG_HOST=op://awx/ocp/api-host
EOF

run_dry() { OPENCODE_SANDBOX_PROFILE="$1" "$LAUNCH" --dry-run serve --hostname=127.0.0.1 --port=5000 2>&1; }

assert_has()  { case "$2" in *"$1"*) ok "$3" ;; *) fail "$3 (missing: $1)" ;; esac; }
assert_lacks(){ case "$2" in *"$1"*) fail "$3 (present: $1)" ;; *) ok "$3" ;; esac; }

echo "==> profile=none (no credentials)"
out=$(run_dry none)
assert_has  "--cap-drop=ALL"         "$out" "hardened: cap-drop ALL"
assert_has  "--userns=keep-id"       "$out" "hardened: userns keep-id"
assert_has  "--network=host"         "$out" "host network (t3 reaches serve)"
assert_has  "serve --hostname=127.0.0.1 --port=5000" "$out" "forwards opencode serve args"
assert_lacks ".config/op:"           "$out" "1Password NOT mounted"
assert_lacks "-e KUBECONFIG"         "$out" "no credentials injected"

echo "==> profile=ocp-cluster-reader (read-only kubeconfig injected)"
out=$(run_dry ocp-cluster-reader)
assert_has  "-e KUBECONFIG=/tmp/kubeconfig-0" "$out" "kubeconfig env injected"
assert_has  "/tmp/kubeconfig-0:ro"   "$out" "kubeconfig mounted read-only"
assert_lacks ".config/op:"           "$out" "1Password still NOT mounted"
assert_has  "serve --hostname=127.0.0.1 --port=5000" "$out" "still forwards serve args"

echo "==> missing profile fails closed"
if OPENCODE_SANDBOX_PROFILE=does-not-exist "$LAUNCH" --dry-run serve >/dev/null 2>&1; then
    fail "unknown profile should exit non-zero"
else
    ok "unknown profile exits non-zero"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
