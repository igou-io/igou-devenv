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

# Parse expected manifest into bash assoc arrays.
# Format: <key> = "<value>"   [# binary: <name>]   [# optional comment]
# - <key>   : mise registry key (matches [tools.<key>] in mise.lock)
# - <value> : expected checksum algorithm prefix in lockfile, OR the literal
#             "core" for tools that use a mise core backend that does not
#             record per-platform checksums in the lockfile (e.g. core:node,
#             which is verified internally by mise against nodejs.org's
#             GPG-signed SHASUMS256.txt but never written to mise.lock).
# - `# binary: <name>` : optional override for the launch-check command name
#                       when the installed binary differs from the mise key
#                       (e.g. tekton-cli installs a binary named `tkn`).
declare -A EXPECTED_MAP
declare -A BINARY_MAP
while IFS= read -r line; do
    # Skip blank lines and pure-comment lines. Use parameter expansion (not
    # xargs) to tolerate apostrophes in commentary like "mise's" / "nodejs.org's".
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in ""|"#"*) continue ;; esac
    # An `=` is required on a real assignment line; skip anything else.
    case "$line" in *=*) ;; *) continue ;; esac
    # Split on the first '=' into key/value-and-trailing-comment.
    k="${line%%=*}"
    rest="${line#*=}"
    # Strip whitespace and surrounding quotes from the key (mise.toml-style
    # backend-prefixed keys like "aqua:nodejs/node" must be quoted in TOML).
    k="$(echo "$k" | tr -d '"' | xargs)"
    # Pull out an optional `# binary: <name>` override from the trailing comment
    # before stripping the comment for the value.
    bin=""
    if echo "$rest" | grep -qE '# *binary: *[^ ]+'; then
        bin="$(echo "$rest" | sed -nE 's/.*# *binary: *([^ #]+).*/\1/p')"
    fi
    # Strip an inline `# ...` comment from the value before stripping quotes.
    v="${rest%%#*}"
    v="$(echo "$v" | tr -d '"' | xargs)"
    [ -n "$k" ] || continue
    EXPECTED_MAP["$k"]="$v"
    if [ -n "$bin" ]; then
        BINARY_MAP["$k"]="$bin"
    fi
done < "$EXPECTED"

# For each tool we expect a verification method for, inspect mise.lock and
# pull out the algorithm prefix from the checksum line. We require the
# tool to have AT LEAST ONE platform-pinned checksum with the expected
# prefix — both linux-x64 and linux-arm64 entries must agree.
#
# Special case: expected = "core" means we explicitly accept that this tool
# uses a mise core backend (e.g. core:node) whose verification happens
# inside mise itself and is not recorded in mise.lock. We still require
# the tool to appear in the lockfile as [[tools.<name>]] to confirm mise
# managed the install.
for tool in "${!EXPECTED_MAP[@]}"; do
    expected="${EXPECTED_MAP[$tool]}"

    # Bracket-quoted keys in the lockfile: a backend-prefixed key like
    # "aqua:nodejs/node" appears as `[[tools."aqua:nodejs/node"]]` rather
    # than the unquoted `[[tools.kubectl]]`. Pick the section header form
    # to look for by detecting whether the key contains TOML-special chars.
    case "$tool" in
        *[!a-zA-Z0-9_-]*) section_open="[[tools.\"${tool}\"]"; section_dot="[tools.\"${tool}\".";;
        *)               section_open="[[tools.${tool}]";      section_dot="[tools.${tool}.";;
    esac

    if [ "$expected" = "core" ]; then
        if grep -qF "$section_open" "$LOCK"; then
            ok "${tool} verified via core backend (mise built-in; no lockfile checksum)"
        else
            fail "${tool}: no ${section_open}] section found in ${LOCK}"
        fi
        continue
    fi

    if [ "$expected" = "postinstall-gpg" ]; then
        # Three assertions for tools verified by a postinstall GPG hook:
        #   1. Tool is in the lockfile (mise managed the install)
        #   2. mise.toml lists `postinstall = "<path>"` for this tool
        #   3. The postinstall script exists and references `gpg`
        if ! grep -qF "$section_open" "$LOCK"; then
            fail "${tool}: no ${section_open}] section found in ${LOCK}"
            continue
        fi
        # Locate the [tools."<key>"] block in mise.toml and grab its
        # postinstall path. The block is identified by its exact header.
        case "$tool" in
            *[!a-zA-Z0-9_-]*) toml_section="[tools.\"${tool}\"]";;
            *)               toml_section="[tools.${tool}]";;
        esac
        post_path=$(awk -v hdr="$toml_section" '
            $0 == hdr { in_block = 1; next }
            /^\[/      { in_block = 0 }
            in_block && /^postinstall *=/ {
                match($0, /"[^"]+"/)
                if (RLENGTH > 0) { print substr($0, RSTART+1, RLENGTH-2); exit }
            }
        ' "${REPO}/mise.toml")
        if [ -z "$post_path" ]; then
            fail "${tool}: mise.toml ${toml_section} has no postinstall = entry"
            continue
        fi
        # Resolve postinstall path against the repo. The Dockerfile copies
        # aqua-registry/ into /etc/mise/aqua-registry/, so the in-toml path
        # /etc/mise/aqua-registry/<file>.sh maps to aqua-registry/<file>.sh.
        case "$post_path" in
            /etc/mise/*) repo_path="${REPO}/${post_path#/etc/mise/}";;
            /*)          repo_path="${post_path}";;
            *)           repo_path="${REPO}/${post_path}";;
        esac
        if [ ! -f "$repo_path" ]; then
            fail "${tool}: postinstall script not found at ${repo_path}"
            continue
        fi
        if ! grep -qE '\bgpg\b' "$repo_path"; then
            fail "${tool}: postinstall script ${repo_path} does not reference gpg"
            continue
        fi
        ok "${tool} verified via postinstall GPG hook (${post_path##*/})"
        continue
    fi

    # Walk the lockfile's [tools.<key>...] sections and harvest two signals:
    #   - the checksum algorithm prefix (text before the first ':' in the
    #     quoted checksum string), and
    #   - the presence of a `[tools.<key>...provenance.<KIND>]` subsection,
    #     which records that mise additionally verified an upstream
    #     attestation (e.g. SLSA L3 provenance for flux2/sops, GitHub
    #     artifact attestations for gh/age).
    # awk state machine: start capture on a section header that begins with
    # either section_open ([[tools.<key>]]) or section_dot ([tools.<key>.X]),
    # emit signal lines, stop on next [section] header that doesn't.
    signals=$(awk -v open="$section_open" -v dot="$section_dot" '
        function startswith(s, p) { return substr(s, 1, length(p)) == p }
        /^\[/{
            in_tool = startswith($0, open) || startswith($0, dot)
            # Also catch `provenance.<KIND>` table headers (e.g.
            # [tools.flux2."platforms.linux-x64".provenance.slsa])
            if (in_tool && match($0, /\.provenance\.[a-zA-Z0-9_-]+/)) {
                kind = substr($0, RSTART+12, RLENGTH-12)
                gsub(/\]/, "", kind)
                print "provenance:" kind
            }
        }
        in_tool && /^checksum *= *"/{
            match($0, /"[^:]+:/)
            if (RLENGTH > 0) {
                alg = substr($0, RSTART+1, RLENGTH-2)
                print "checksum:" alg
            }
        }
    ' "$LOCK" | sort -u)

    algs=$(echo "$signals" | awk -F: '/^checksum:/{print $2}' | sort -u)
    provs=$(echo "$signals" | awk -F: '/^provenance:/{print $2}' | sort -u)

    if [ -z "$algs" ]; then
        fail "${tool}: no checksum found in ${LOCK}"
        continue
    fi

    # Expected may be a compound form "<alg>+<provenance>", e.g. "sha256+slsa",
    # which asserts both the checksum prefix AND the presence of a matching
    # provenance subsection on every covered platform.
    case "$expected" in
        *+*)
            exp_alg="${expected%%+*}"
            exp_prov="${expected#*+}"
            ;;
        *)
            exp_alg="$expected"
            exp_prov=""
            ;;
    esac

    # Every platform's checksum prefix must equal exp_alg.
    mismatch=""
    for a in $algs; do
        if [ "$a" != "$exp_alg" ]; then
            mismatch="$a"
            break
        fi
    done
    if [ -n "$mismatch" ]; then
        fail "${tool}: lockfile uses ${mismatch} (expected ${exp_alg})"
        continue
    fi

    if [ -n "$exp_prov" ]; then
        if ! echo "$provs" | grep -qFx "$exp_prov"; then
            fail "${tool}: lockfile has no provenance.${exp_prov} entry (expected for compound ${expected})"
            continue
        fi
        ok "${tool} verified via ${exp_alg} + ${exp_prov} provenance"
    else
        ok "${tool} verified via ${exp_alg}"
    fi
done

echo ""
echo "==> Binary launch check (every tool in mise.toml runs --version)"
for tool in "${!EXPECTED_MAP[@]}"; do
    bin="${BINARY_MAP[$tool]:-$tool}"
    if "$bin" --version >/dev/null 2>&1 \
        || "$bin" version --client >/dev/null 2>&1 \
        || "$bin" version >/dev/null 2>&1 \
        || "$bin" -v >/dev/null 2>&1; then
        if [ "$bin" != "$tool" ]; then
            ok "$tool launches (binary: $bin)"
        else
            ok "$tool launches"
        fi
    else
        fail "$tool failed to launch (tried binary: $bin)"
    fi
done

echo ""
echo "==> Summary: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
