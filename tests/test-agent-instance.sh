#!/usr/bin/env bash
# Tests .devcontainer/agent-sandbox-launch — the driver-agnostic scoped-session
# launcher behind t3 provider instances (adr/0006). Mock op + mock podman +
# --dry-run: no 1Password, image, or container needed (CI-safe).
# shellcheck disable=SC2015,SC2016
set -u

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH="$REPO_DIR/.devcontainer/agent-sandbox-launch"

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
assert_has()  { case "$2" in *"$1"*) ok "$3" ;; *) fail "$3 (missing: $1)" ;; esac; }
assert_lacks(){ case "$2" in *"$1"*) fail "$3 (present: $1)" ;; *) ok "$3" ;; esac; }

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

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

# Isolated HOME so per-scope homes and shims land in the test dir.
export HOME="$TESTDIR/home"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.t3/userdata/attachments"
echo '{"model":"opus","permissions":{"allow":["Bash(ls*)"]}}' > "$HOME/.claude/settings.json"
echo '{"oauthAccount":"x"}' > "$HOME/.claude.json"
echo '{"claudeAiOauth":{"accessToken":"x"}}' > "$HOME/.claude/.credentials.json"
printf 'model_reasoning_effort = "high"\n' > "$HOME/.codex/config.toml"
echo '{"tokens":"x"}' > "$HOME/.codex/auth.json"

export MOCK_OP_SECRETS_FILE="$TESTDIR/mock-secrets"
KEYFILE="$TESTDIR/fake-key"; printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEYFILE"
cat > "$MOCK_OP_SECRETS_FILE" << EOS
op://awx/ocp/reader-token=sha256~fake-reader-token
op://awx/ocp/api-host=https://api.ocp.igou.systems:6443
op://lab_ssh/ansible/private key?ssh-format=openssh=file:${KEYFILE}
EOS

export AGENT_SANDBOX_ENVDIR="$TESTDIR/envs"
export AGENT_SANDBOX_PERMDIR="$REPO_DIR/envs/permissions"
mkdir -p "$AGENT_SANDBOX_ENVDIR"
cat > "$AGENT_SANDBOX_ENVDIR/ocp-cluster-reader.env" << 'EOF2'
KUBECONFIG_TOKEN=op://awx/ocp/reader-token
KUBECONFIG_HOST=op://awx/ocp/api-host
PERMISSIONS=readonly
EOF2
cat > "$AGENT_SANDBOX_ENVDIR/ansible.env" << 'EOF2'
ANSIBLE_INVENTORY=/workspace/igou-inventory
SSH_KEYS=ansible
EOF2
cat > "$AGENT_SANDBOX_ENVDIR/bad-perms.env" << 'EOF2'
PERMISSIONS=does-not-exist
EOF2
cat > "$AGENT_SANDBOX_ENVDIR/rk8s-cluster-reader.env" << 'EOF2'
KUBECONFIG_TOKEN=op://awx/ocp/reader-token
KUBECONFIG_HOST=https://cm3588-nas-01.igou.systems:6443
PERMISSIONS=readonly
EOF2
cat > "$AGENT_SANDBOX_ENVDIR/read-only.env" << 'EOF2'
INCLUDE=ocp-cluster-reader,rk8s-cluster-reader,ansible
PERMISSIONS=readonly
EOF2

run_dry() { local p="$1"; shift; AGENT_SANDBOX_PROFILES="$p" "$LAUNCH" --dry-run "$@" 2>&1; }

echo "==> common hardening (claude, profile=none)"
out=$(run_dry none --output-format stream-json)
assert_has  "--cap-drop=ALL"          "$out" "cap-drop ALL"
assert_has  "--userns=keep-id"        "$out" "userns keep-id"
assert_has  "no-new-privileges"       "$out" "no-new-privileges"
assert_lacks ".config/op:"            "$out" "1Password NOT mounted"
assert_lacks "-e KUBECONFIG"          "$out" "no credentials injected"
assert_has  "-e AGENT_PROFILE=none"   "$out" "AGENT_PROFILE exported"
assert_has  "/.claude:/home/igou/.claude:Z" "$out" "profile=none keeps the shared ~/.claude"
assert_has  ".t3/userdata/attachments:" "$out" "t3 attachments dir mounted (add-dir target)"
assert_has  "attachments:ro"           "$out" "t3 attachments mounted read-only"

echo "==> claude: stdio, scoped home, permissions"
out=$(run_dry ocp-cluster-reader --output-format stream-json --verbose)
assert_has  " -i "                    "$out" "stdio: -i"
assert_lacks " -it "                  "$out" "stdio: no tty"
assert_has  "--network=host"          "$out" "host network (t3 MCP on 127.0.0.1:3773)"
assert_lacks "--name"                 "$out" "stdio: no fixed container name (parallel sessions)"
assert_has  "ghcr.io/igou-io/claude-code:latest claude --output-format stream-json --verbose" "$out" "forwards claude args verbatim"
assert_has  "-e KUBECONFIG=/tmp/kubeconfig-0" "$out" "kubeconfig env injected"
assert_has  "/tmp/kubeconfig-0:ro"    "$out" "kubeconfig mounted read-only"
assert_lacks "PERMISSIONS="           "$out" "PERMISSIONS key not leaked as env"
assert_has  ".claude-ocp-cluster-reader:/home/igou/.claude:Z" "$out" "per-scope claude home"
CH="$HOME/.claude-ocp-cluster-reader"
if grep -q 'Session scope: ocp-cluster-reader' "$CH/CLAUDE.md" 2>/dev/null; then ok "scope note written to CLAUDE.md"; else fail "scope note written to CLAUDE.md"; fi
if grep -q 'permission level `readonly`' "$CH/CLAUDE.md" 2>/dev/null; then ok "scope note names permission level"; else fail "scope note names permission level"; fi
if [ "$(jq -r '.model' "$CH/settings.json")" = "opus" ] && jq -e '.permissions.deny | index("Bash(oc apply*)")' "$CH/settings.json" >/dev/null \
   && jq -e '.permissions.allow | index("Bash(oc get*)")' "$CH/settings.json" >/dev/null; then
    ok "settings.json = host settings merged with readonly fragment"
else
    fail "settings.json = host settings merged with readonly fragment"
fi
[ -f "$CH/.claude-state.json" ] && ok "claude.json snapshot seeded" || fail "claude.json snapshot seeded"
if [ -f "$CH/.credentials.json" ] && [ "$(stat -c %a "$CH/.credentials.json")" = "600" ]; then ok "OAuth credentials seeded into scoped home (0600)"; else fail "OAuth credentials seeded into scoped home (0600)"; fi

echo "==> codex: inferred from app-server, CODEX_HOME, config overlay"
out=$(run_dry ocp-cluster-reader app-server --listen stdio://)
assert_has  "ghcr.io/igou-io/codex:latest codex app-server --listen stdio://" "$out" "driver inferred + args forwarded"
assert_has  " -i "                    "$out" "stdio: -i"
assert_has  ".codex-ocp-cluster-reader:/home/igou/.codex:Z" "$out" "per-scope codex home"
assert_has  "-e CODEX_HOME=/home/igou/.codex" "$out" "CODEX_HOME set"
CX="$HOME/.codex-ocp-cluster-reader"
[ -f "$CX/auth.json" ] && ok "codex auth.json seeded" || fail "codex auth.json seeded"
if grep -q 'model_reasoning_effort' "$CX/config.toml" && grep -q 'sandbox_mode = "read-only"' "$CX/config.toml"; then ok "config.toml = host + readonly overlay"; else fail "config.toml = host + readonly overlay"; fi
grep -q 'Session scope' "$CX/AGENTS.md" && ok "scope note in AGENTS.md" || fail "scope note in AGENTS.md"

echo "==> opencode: inferred from serve, host network, config content"
out=$(run_dry ocp-cluster-reader serve --hostname=127.0.0.1 --port=5000)
assert_has  "--network=host"          "$out" "host network"
assert_has  "--name opencode-instance-ocp-cluster-reader" "$out" "fixed server name"
assert_has  ".cache/opencode:/home/igou/.cache/opencode:Z" "$out" "models.dev cache mounted (fresh model catalog)"
assert_has  "opencode serve --hostname=127.0.0.1 --port=5000" "$out" "forwards serve args"
assert_has  "OPENCODE_CONFIG_CONTENT=" "$out" "config content injected"
assert_has  '/etc/agent/scope.md'     "$out" "scope note mounted + referenced"
assert_has  'edit\":\"deny'           "$out" "readonly permission in config content"
assert_lacks " -i "                   "$out" "server: no -i"

echo "==> stacking + SSH keys (claude)"
out=$(run_dry ocp-cluster-reader,ansible)
assert_has  "-e ANSIBLE_INVENTORY=/workspace/igou-inventory" "$out" "second profile vars injected"
assert_has  "/tmp/agent-ssh-keys:ro"  "$out" "ssh keys mounted read-only"
assert_has  "ssh-agent"               "$out" "per-session ssh-agent started in container"
assert_lacks "ssh-agent.sock"         "$out" "host ssh-agent socket NOT mounted"
assert_has  ".claude-ocp-cluster-reader-ansible:" "$out" "stacked scope slug in home"
assert_lacks "SSH_KEYS="              "$out" "SSH_KEYS key not leaked as env"

echo "==> bundle profile (INCLUDE): two kubeconfigs, one KUBECONFIG list"
out=$(run_dry read-only)
assert_has  "/tmp/kubeconfig-0:ro"    "$out" "first kubeconfig mounted"
assert_has  "/tmp/kubeconfig-1:ro"    "$out" "second kubeconfig mounted"
assert_has  "-e KUBECONFIG=/tmp/kubeconfig-0:/tmp/kubeconfig-1" "$out" "KUBECONFIG is the merged list"
assert_has  "-e ANSIBLE_INVENTORY="   "$out" "included plain profile vars present"
assert_has  "/tmp/agent-ssh-keys:ro"  "$out" "included SSH_KEYS honoured"
assert_has  "-e AGENT_PROFILE=read-only" "$out" "bundle name is the scope"
assert_has  ".claude-read-only:"      "$out" "bundle name is the home slug"
if grep -q 'get-contexts' "$HOME/.claude-read-only/CLAUDE.md"; then ok "scope note explains multi-context KUBECONFIG"; else fail "scope note explains multi-context KUBECONFIG"; fi

echo "==> explicit driver + shell"
out=$(AGENT_SANDBOX_DRIVER=codex run_dry none --shell)
assert_has  " -it "                   "$out" "--shell gets a tty"
assert_has  "ghcr.io/igou-io/codex:latest bash" "$out" "--shell runs bash"

echo "==> failure modes"
if AGENT_SANDBOX_PROFILES=does-not-exist "$LAUNCH" --dry-run >/dev/null 2>&1; then fail "unknown profile exits non-zero"; else ok "unknown profile exits non-zero"; fi
for d in claude codex opencode; do
    if AGENT_SANDBOX_DRIVER=$d AGENT_SANDBOX_PROFILES=bad-perms "$LAUNCH" --dry-run >/dev/null 2>&1; then fail "$d: unknown permission level exits non-zero"; else ok "$d: unknown permission level exits non-zero"; fi
done
if AGENT_SANDBOX_DRIVER=nope "$LAUNCH" --dry-run >/dev/null 2>&1; then fail "unknown driver exits non-zero"; else ok "unknown driver exits non-zero"; fi
if [ "$(AGENT_SANDBOX_PROFILES=does-not-exist "$LAUNCH" --dry-run 2>/dev/null | wc -c)" = "0" ]; then ok "failure prints nothing on stdout"; else fail "failure prints nothing on stdout"; fi

echo "==> --install-shim"
AGENT_SANDBOX_SHIM_DIR="$TESTDIR/shims" "$LAUNCH" --install-shim ocp-cluster-reader >/dev/null 2>&1
S="$TESTDIR/shims/agent-sandbox-launch-ocp-cluster-reader"
[ -x "$S" ] && ok "shim written + executable" || fail "shim written + executable"
out=$("$S" --dry-run serve --port=1 2>&1)
assert_has "--name opencode-instance-ocp-cluster-reader" "$out" "shim pins the profile"
out=$("$S" --dry-run --version 2>&1)
assert_has "ghcr.io/igou-io/opencode:latest opencode --version" "$out" "shim pins the opencode driver for t3 probes"

echo "==> temp files cleaned"
n=$(find /tmp -maxdepth 1 \( -name 'agent-ssh-keys.*' -o -name 'agent-scope.*' \) -newer "$TESTDIR/bin/podman" | wc -l)
[ "$n" = "0" ] && ok "no leftover temp files" || fail "no leftover temp files ($n left)"

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
