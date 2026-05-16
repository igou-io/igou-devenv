#!/usr/bin/env bash
# Verification audit: assert each tool in mise.toml resolves to the
# verification method declared in tests/mise-expected-verification.toml.
# Catches silent aqua-registry downgrades (e.g., argocd SLSA -> SHA-only).
#
# Runs inside the devcontainer (sees the installed mise + tool data).
#
# Source of truth for "what verification did mise use" is the lockfile
# at /etc/mise/mise.lock (or the repo's mise.lock when run from a
# checkout). Lockfile checksums are prefixed with the algorithm name:
#   checksum = "sha256:..."   # aqua-published checksum, verified upstream
#   checksum = "blake3:..."   # TOFU: mise computed it on first install
# The prefix is the audit signal.
set -euo pipefail

# Locate the lockfile. Inside the built devcontainer it lives at /etc/mise;
# during host-side dev runs (e.g. `bash tests/test-mise.sh` against a
# checkout) fall back to the repo copy.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f /etc/mise/mise.lock ]; then
    LOCK=/etc/mise/mise.lock
else
    LOCK="${REPO}/mise.lock"
fi
EXPECTED="${REPO}/tests/mise-expected-verification.toml"

if [ ! -f "$LOCK" ]; then
    echo "[FAIL] lockfile not found at /etc/mise/mise.lock or ${REPO}/mise.lock"
    exit 1
fi

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Mise version pin check"
DOCKERFILE_VERSION=$(awk -F'"' '/^ARG MISE_VERSION/{print $2; exit}' "${REPO}/.devcontainer/Dockerfile")
DOCKERFILE_VERSION="${DOCKERFILE_VERSION#v}"   # strip leading 'v'
INSTALLED_VERSION=$(mise --version | awk '{print $1}')
if [ "$DOCKERFILE_VERSION" = "$INSTALLED_VERSION" ]; then
    ok "mise version matches pinned MISE_VERSION in Dockerfile (${INSTALLED_VERSION})"
else
    fail "mise version drift: Dockerfile pins ${DOCKERFILE_VERSION}, installed is ${INSTALLED_VERSION}"
fi

echo ""
echo "==> Verification audit (per tool in mise.toml, checked against mise.lock)"

# Parse expected manifest into a bash assoc array.
# Format: <key> = "<value>"   [# optional comment]
# We strip the inline comment, quotes, and surrounding whitespace.
declare -A EXPECTED_MAP
while IFS='=' read -r k v; do
    k="$(echo "$k" | xargs)"
    # Strip an inline `# ...` comment from the value before stripping quotes.
    v="${v%%#*}"
    v="$(echo "$v" | tr -d '"' | xargs)"
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] && EXPECTED_MAP["$k"]="$v"
done < "$EXPECTED"

# For each tool we expect a verification method for, inspect mise.lock and
# pull out the algorithm prefix from the checksum line. We require the
# tool to have AT LEAST ONE platform-pinned checksum with the expected
# prefix — both linux-x64 and linux-arm64 entries must agree.
for tool in "${!EXPECTED_MAP[@]}"; do
    expected="${EXPECTED_MAP[$tool]}"

    # Pull all checksum lines under [tools.<tool>...] sections from the
    # lockfile and extract the algorithm prefix (text before ':').
    # awk state machine: start capture on a section header matching the
    # tool, emit checksum lines, stop on next [section] header.
    algs=$(awk -v t="$tool" '
        /^\[/{
            in_tool = ($0 ~ "^\\[\\[?tools\\." t "\\b") || ($0 ~ "^\\[tools\\." t "\\.")
        }
        in_tool && /^checksum *= *"/{
            match($0, /"[^:]+:/)
            if (RLENGTH > 0) {
                alg = substr($0, RSTART+1, RLENGTH-2)
                print alg
            }
        }
    ' "$LOCK" | sort -u)

    if [ -z "$algs" ]; then
        fail "${tool}: no checksum found in ${LOCK}"
        continue
    fi

    # Every platform's checksum must match expected.
    mismatch=""
    for a in $algs; do
        if [ "$a" != "$expected" ]; then
            mismatch="$a"
            break
        fi
    done
    if [ -n "$mismatch" ]; then
        fail "${tool}: lockfile uses ${mismatch} (expected ${expected})"
    else
        ok "${tool} verified via ${expected}"
    fi
done

echo ""
echo "==> Binary launch check (every tool in mise.toml runs --version)"
for tool in "${!EXPECTED_MAP[@]}"; do
    if "$tool" --version >/dev/null 2>&1 \
        || "$tool" version --client >/dev/null 2>&1 \
        || "$tool" version >/dev/null 2>&1 \
        || "$tool" -v >/dev/null 2>&1; then
        ok "$tool launches"
    else
        fail "$tool failed to launch"
    fi
done

echo ""
echo "==> Summary: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
