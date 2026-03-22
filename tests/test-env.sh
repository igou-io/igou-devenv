#!/usr/bin/env bash
# Test environment switching shell functions (use, k8s-unset, prompt).
# Must be run with bash -i (interactive) so .bashrc is sourced.
# No set -e or pipefail — test pass/fail is tracked via PASS/FAIL counters.
set -u

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Testing use() with missing env..."
if use nonexistent 2>&1 | grep -q "No env file"; then ok "missing env shows error"; else fail "missing env shows error"; fi

echo ""
echo "==> Testing use() lists available envs..."
if ls /workspace/igou-devenv/envs/*.env 2>/dev/null | grep -q env; then
    ok "env files listable"
else
    fail "env files listable"
fi

echo ""
echo "==> Testing OP_ENV stacking..."
if OP_ENV="k3s" bash -c '[ "$OP_ENV" = "k3s" ]'; then ok "OP_ENV set"; else fail "OP_ENV set"; fi
if OP_ENV="k3s" bash -c 'export OP_ENV="${OP_ENV:+$OP_ENV/}aap"; [ "$OP_ENV" = "k3s/aap" ]'; then
    ok "OP_ENV stacks"
else
    fail "OP_ENV stacks"
fi

echo ""
echo "==> Testing k8s-unset..."
export KUBECONFIG=/tmp/fake K8S_AUTH_HOST=fake K8S_AUTH_API_KEY=fake
k8s-unset > /dev/null
if [ -z "${KUBECONFIG:-}" ] && [ -z "${K8S_AUTH_HOST:-}" ] && [ -z "${K8S_AUTH_API_KEY:-}" ]; then
    ok "k8s-unset clears vars"
else
    fail "k8s-unset clears vars"
fi

echo ""
echo "==> Testing prompt functions..."
if [ -n "$(type -t __prompt_command)" ]; then ok "__prompt_command defined"; else fail "__prompt_command defined"; fi
if echo "$PROMPT_COMMAND" | grep -q __prompt_command; then ok "PROMPT_COMMAND set"; else fail "PROMPT_COMMAND set"; fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
