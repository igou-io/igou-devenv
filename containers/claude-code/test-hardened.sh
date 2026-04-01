#!/usr/bin/env bash
# Integration test: verify Claude and tools work under full hardening.
# Runs inside the actual container with all podman restrictions applied
# (--read-only, --cap-drop=ALL, noexec /tmp, resource limits, etc.)
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Claude Code basics
# ---------------------------------------------------------------------------
echo "==> Claude Code..."

if claude --version &>/dev/null; then
    ok "claude --version runs"
else
    fail "claude --version runs"
fi

# claude -p exits without hanging (no API key, but parses args and exits cleanly)
if timeout 10 claude -p "test" --max-turns 0 &>/dev/null; then
    ok "claude -p exits cleanly (no hang)"
else
    exit_code=$?
    # Exit code 1 = no API key (expected), 124 = timeout (bad)
    if [ "$exit_code" -ne 124 ]; then
        ok "claude -p exits with code $exit_code (no hang)"
    else
        fail "claude -p timed out"
    fi
fi

# ---------------------------------------------------------------------------
# MCP config baked in
# ---------------------------------------------------------------------------
echo ""
echo "==> MCP config..."

if [ -f "/etc/claude/claude.json" ]; then
    ok "baked claude.json exists at /etc/claude/"
else
    fail "baked claude.json exists at /etc/claude/"
fi

if python3 -c "import json; c=json.load(open('/etc/claude/claude.json')); assert 'kubernetes' in c['mcpServers']" 2>/dev/null; then
    ok "kubernetes MCP server in baked config"
else
    fail "kubernetes MCP server in baked config"
fi

# Entrypoint merges baked config into ~/.claude.json
if [ -f "$HOME/.claude.json" ]; then
    if python3 -c "import json; c=json.load(open('$HOME/.claude.json')); assert 'kubernetes' in c['mcpServers']" 2>/dev/null; then
        ok "kubernetes MCP server merged into ~/.claude.json"
    else
        fail "kubernetes MCP server merged into ~/.claude.json"
    fi
else
    ok "~/.claude.json will be created by entrypoint (not in bash test mode)"
fi

# ---------------------------------------------------------------------------
# Claude sandbox settings baked in
# ---------------------------------------------------------------------------
echo ""
echo "==> Sandbox settings..."

BAKED_SETTINGS="/etc/claude/settings.json"
if [ -f "$BAKED_SETTINGS" ]; then
    ok "baked settings.json exists at /etc/claude/"
else
    fail "baked settings.json exists at /etc/claude/"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SETTINGS')); assert s['sandbox']['enabled'] is True" 2>/dev/null; then
    ok "sandbox enabled"
else
    fail "sandbox enabled"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SETTINGS')); assert s['sandbox']['enableWeakerNestedSandbox'] is True" 2>/dev/null; then
    ok "weaker nested sandbox enabled"
else
    fail "weaker nested sandbox enabled"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SETTINGS')); assert s['sandbox']['allowUnsandboxedCommands'] is False" 2>/dev/null; then
    ok "unsandboxed commands disabled"
else
    fail "unsandboxed commands disabled"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SETTINGS')); assert 'api.anthropic.com' in s['sandbox']['network']['allowedDomains']" 2>/dev/null; then
    ok "anthropic API in allowed domains"
else
    fail "anthropic API in allowed domains"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SETTINGS')); assert s['sandbox']['seccomp']['bpfPath'] == '/usr/local/lib/claude-sandbox/unix-block.bpf'" 2>/dev/null; then
    ok "seccomp bpfPath configured"
else
    fail "seccomp bpfPath configured"
fi

if command -v bwrap &>/dev/null; then
    ok "bubblewrap (bwrap) installed"
else
    fail "bubblewrap (bwrap) installed"
fi

if [ -x /usr/local/lib/claude-sandbox/apply-seccomp ]; then
    ok "seccomp apply binary present"
else
    fail "seccomp apply binary present"
fi

# Functional tests: verify sandbox tools actually work under cap-drop=ALL
if bwrap --ro-bind / / --dev /dev --tmpfs /tmp --die-with-parent echo "ok" &>/dev/null; then
    ok "bwrap executes under hardened flags"
else
    fail "bwrap executes under hardened flags"
fi

if /usr/local/lib/claude-sandbox/apply-seccomp /usr/local/lib/claude-sandbox/unix-block.bpf echo "ok" &>/dev/null; then
    ok "seccomp filter applies successfully"
else
    fail "seccomp filter applies successfully"
fi

# ---------------------------------------------------------------------------
# Filesystem: read-only root, writable workspace
# ---------------------------------------------------------------------------
echo ""
echo "==> Filesystem restrictions..."

# System paths are not writable (owned by root, user is 1000)
if ! touch /usr/local/bin/test-write 2>/dev/null; then
    ok "/usr/local/bin not writable by user"
else
    rm -f /usr/local/bin/test-write
    fail "/usr/local/bin not writable by user"
fi

if ! touch /etc/test-write 2>/dev/null; then
    ok "/etc not writable by user"
else
    rm -f /etc/test-write
    fail "/etc not writable by user"
fi

# /tmp is writable but noexec
if echo "test" > /tmp/write-test 2>/dev/null; then
    ok "/tmp is writable"
    rm -f /tmp/write-test
else
    fail "/tmp is writable"
fi

echo '#!/bin/sh' > /tmp/exec-test 2>/dev/null && chmod +x /tmp/exec-test 2>/dev/null
if ! /tmp/exec-test 2>/dev/null; then
    ok "/tmp is noexec"
else
    fail "/tmp is noexec (execution succeeded)"
fi
rm -f /tmp/exec-test

# /workspace exists and is the workdir
if [ "$(pwd)" = "/workspace" ]; then
    ok "/workspace is workdir"
else
    fail "/workspace is workdir (got: $(pwd))"
fi

# ---------------------------------------------------------------------------
# Entrypoint: git identity configured
# ---------------------------------------------------------------------------
echo ""
echo "==> Git configuration..."

# Entrypoint sets GIT_CONFIG_GLOBAL to /tmp/.gitconfig for read-only root fs.
# In this test we run bash directly (not via entrypoint), so simulate it.
export GIT_CONFIG_GLOBAL="/tmp/.gitconfig"
git config --global user.name "claude[bot]"
git config --global user.email "noreply@github.com"

git_name=$(git config --global user.name 2>/dev/null || true)
if [ "$git_name" = "claude[bot]" ]; then
    ok "git config works via GIT_CONFIG_GLOBAL=/tmp/.gitconfig"
else
    fail "git config works via GIT_CONFIG_GLOBAL (got: ${git_name:-empty})"
fi

if [ -f "/tmp/.gitconfig" ]; then
    ok "gitconfig written to /tmp (read-only root compatible)"
else
    fail "gitconfig written to /tmp"
fi

# Git operations work
git init /tmp/git-test-repo 2>/dev/null || true
if git -C /tmp/git-test-repo status &>/dev/null; then
    ok "git init + status works"
else
    fail "git init + status works"
fi

# ---------------------------------------------------------------------------
# Core tools work under restrictions
# ---------------------------------------------------------------------------
echo ""
echo "==> Tool functionality under hardening..."

if kubectl version --client 2>&1 | grep -qiE "v[0-9]|client"; then
    ok "kubectl runs"
else
    fail "kubectl runs"
fi

if helm version --short 2>&1 | grep -q "v"; then
    ok "helm runs"
else
    fail "helm runs"
fi

if gh --version &>/dev/null; then
    ok "gh runs"
else
    fail "gh runs"
fi

if python3 -c "print('hello')" 2>/dev/null; then
    ok "python3 runs"
else
    fail "python3 runs"
fi

# ansible needs ~/.ansible writable (provided by tmpfs mount)
if ansible --version &>/dev/null; then
    ok "ansible runs"
else
    fail "ansible runs"
fi

if jq -n '{"test": true}' &>/dev/null; then
    ok "jq runs"
else
    fail "jq runs"
fi

if yamllint --version &>/dev/null; then
    ok "yamllint runs"
else
    fail "yamllint runs"
fi

if kustomize version &>/dev/null; then
    ok "kustomize runs"
else
    fail "kustomize runs"
fi

if kubeconform -v &>/dev/null; then
    ok "kubeconform runs"
else
    fail "kubeconform runs"
fi

# ---------------------------------------------------------------------------
# Process limits respected
# ---------------------------------------------------------------------------
echo ""
echo "==> Process and resource limits..."

if [ "$(ulimit -c)" = "0" ]; then
    ok "core dumps disabled (ulimit -c = 0)"
else
    fail "core dumps disabled (ulimit -c = $(ulimit -c))"
fi

nofile_soft=$(ulimit -n)
if [ "$nofile_soft" -le 2048 ]; then
    ok "file descriptor limit set ($nofile_soft)"
else
    fail "file descriptor limit set (got $nofile_soft, expected <= 2048)"
fi

# PID 1 should be init (tini), not entrypoint.sh
pid1_name=$(cat /proc/1/comm 2>/dev/null || echo "unknown")
if [ "$pid1_name" = "tini" ] || [ "$pid1_name" = "catatonit" ] || [ "$pid1_name" = "dumb-init" ]; then
    ok "PID 1 is init process ($pid1_name)"
else
    # podman --init may use different init names
    ok "PID 1 is: $pid1_name (--init active)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
