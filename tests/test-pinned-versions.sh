#!/usr/bin/env bash
# Verifies that the binary versions actually installed in the container match
# the version ARGs declared in the Dockerfile that produced this image. Guards
# against installer drift (e.g. a "latest"-resolving installer or a Dockerfile
# bump that wasn't accompanied by a SHA256 update).
set -euo pipefail

DOCKERFILE="${DOCKERFILE:-/workspace/igou-devenv/.devcontainer/Dockerfile}"
PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

get_arg() {
    # Extract: ARG NAME="value"  →  value
    grep -oE "^ARG $1=\"[^\"]+\"" "$DOCKERFILE" \
      | sed -E "s/^ARG $1=\"([^\"]+)\"/\1/" \
      | head -1
}

assert_version() {
    local name="$1" cmd="$2" expected="$3"
    if [ -z "$expected" ]; then
        fail "$name: no ARG found in $DOCKERFILE"
        return
    fi
    # Strip optional leading "v" so "v2.1.142" matches "2.1.142" in output.
    local needle="${expected#v}"
    local actual
    actual=$($cmd 2>&1 | head -3 || true)
    if echo "$actual" | grep -qF "$needle"; then
        ok "$name pinned to $expected"
    else
        fail "$name: expected $expected, got: $(echo "$actual" | head -1)"
    fi
}

echo "==> Verifying pinned tool versions match Dockerfile ARGs..."

assert_version "claude"       "claude --version"     "$(get_arg CLAUDE_CODE_VERSION)"
assert_version "cursor-agent" "agent --version"      "$(get_arg CURSOR_AGENT_VERSION)"
assert_version "opencode"     "opencode --version"   "$(get_arg OPENCODE_VERSION)"

# H3 tier spot-checks — one tool per verification tier to catch drift.
assert_version "terraform"    "terraform version"        "$(get_arg TERRAFORM_VERSION)"
assert_version "flux"         "flux --version"           "$(get_arg FLUX_VERSION)"
assert_version "kubectl"      "kubectl version --client" "$(get_arg KUBECTL_VERSION)"
assert_version "direnv"       "direnv version"           "$(get_arg DIRENV_VERSION)"

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
