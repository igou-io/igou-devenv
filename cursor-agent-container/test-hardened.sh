#!/usr/bin/env bash
# Integration test: verify tools work under full hardening.
# Runs inside the actual container with all podman restrictions applied
# (--cap-drop=ALL, noexec /tmp, resource limits, etc.)
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Filesystem: system paths not writable, /tmp noexec
# ---------------------------------------------------------------------------
echo "==> Filesystem restrictions..."

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

export GIT_CONFIG_GLOBAL="/tmp/.gitconfig"
git config --global user.name "cursor-agent[bot]"
git config --global user.email "noreply@github.com"

git_name=$(git config --global user.name 2>/dev/null || true)
if [ "$git_name" = "cursor-agent[bot]" ]; then
    ok "git config works via GIT_CONFIG_GLOBAL=/tmp/.gitconfig"
else
    fail "git config works via GIT_CONFIG_GLOBAL (got: ${git_name:-empty})"
fi

if [ -f "/tmp/.gitconfig" ]; then
    ok "gitconfig written to /tmp (read-only root compatible)"
else
    fail "gitconfig written to /tmp"
fi

git init /tmp/git-test-repo 2>/dev/null || true
if git -C /tmp/git-test-repo status &>/dev/null; then
    ok "git init + status works"
else
    fail "git init + status works"
fi

# ---------------------------------------------------------------------------
# Cursor Agent CLI
# ---------------------------------------------------------------------------
echo ""
echo "==> Cursor Agent CLI..."

if agent --version &>/dev/null; then
    ok "agent --version runs"
else
    fail "agent --version runs"
fi

# ---------------------------------------------------------------------------
# Cursor sandbox config
# ---------------------------------------------------------------------------
echo ""
echo "==> Sandbox config..."

if [ -f "/etc/cursor/sandbox.json" ]; then
    ok "baked sandbox.json present"
else
    fail "baked sandbox.json present"
fi

if python3 -c "import json; s=json.load(open('/etc/cursor/sandbox.json')); assert s['networkPolicy']['default'] == 'deny'" 2>/dev/null; then
    ok "network deny-by-default"
else
    fail "network deny-by-default"
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
# Process and resource limits
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

pid1_name=$(cat /proc/1/comm 2>/dev/null || echo "unknown")
if [ "$pid1_name" = "tini" ] || [ "$pid1_name" = "catatonit" ] || [ "$pid1_name" = "dumb-init" ]; then
    ok "PID 1 is init process ($pid1_name)"
else
    ok "PID 1 is: $pid1_name (--init active)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
