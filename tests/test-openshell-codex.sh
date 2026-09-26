#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

mkdir -p "$TESTDIR/bin"
MOCK_LOG="$TESTDIR/openshell.log"
export MOCK_LOG

cat >"$TESTDIR/bin/openshell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${1:-}" == "--gateway" ]]; then
    shift 2
fi

case "${1:-} ${2:-}" in
    "policy get")
        printf '%s\n' '{"policy":{"network_policies":[{"name":"opencode"}]}}'
        ;;
esac
EOF
chmod +x "$TESTDIR/bin/openshell"

export PATH="$TESTDIR/bin:$PATH"
export OPENSHELL_CODEX_IMAGE=registry.example.com/agents/codex:1.0

output=$(cd "$REPO_DIR" && bin/openshell-codex \
    --name test-codex \
    --ephemeral \
    -- exec 'Reply with OK')

grep -q -- '--gateway ocp status' "$MOCK_LOG"
grep -q -- '--gateway ocp provider get opencode-go' "$MOCK_LOG"
grep -q -- 'sandbox create --name test-codex --provider opencode-go --cpu 2 --memory 4Gi --detach' "$MOCK_LOG"
grep -q -- "--upload $REPO_DIR:/sandbox" "$MOCK_LOG"
grep -q -- '--from registry.example.com/agents/codex:1.0' "$MOCK_LOG"
if grep -q -- 'policy update' "$MOCK_LOG"; then
    echo 'wrapper unexpectedly modified the selected image policy' >&2
    exit 1
fi
grep -q -- 'model_providers.opencode_go.base_url=' "$MOCK_LOG"
grep -q -- '--model gpt-5.6-luna --sandbox danger-full-access exec --skip-git-repo-check' "$MOCK_LOG"
grep -q -- 'sandbox delete test-codex' "$MOCK_LOG"
grep -q -- 'Creating OpenShell sandbox test-codex' <<<"$output"
grep -q -- 'Launching Codex in test-codex' <<<"$output"

dry_run=$(cd "$REPO_DIR" && bin/openshell-codex \
    --name retained-codex \
    --no-upload \
    --dry-run)
grep -q -- 'sandbox create' <<<"$dry_run"
if grep -q -- '--upload' <<<"$dry_run"; then
    echo 'dry-run unexpectedly included --upload' >&2
    exit 1
fi
if grep -q -- 'sandbox delete' <<<"$dry_run"; then
    echo 'retained dry-run unexpectedly included sandbox deletion' >&2
    exit 1
fi

if "$REPO_DIR/bin/openshell-codex" --name 'Invalid_Name' --dry-run >/dev/null 2>&1; then
    echo 'invalid sandbox name unexpectedly succeeded' >&2
    exit 1
fi

if OPENSHELL_CODEX_IMAGE='' "$REPO_DIR/bin/openshell-codex" --dry-run >/dev/null 2>&1; then
    echo 'missing agent image unexpectedly succeeded' >&2
    exit 1
fi

explicit_image=$("$REPO_DIR/bin/openshell-codex" --image registry.example.com/custom/codex:2 --dry-run)
grep -q -- '--from registry.example.com/custom/codex:2' <<<"$explicit_image"

echo '[OK] openshell-codex wrapper'
