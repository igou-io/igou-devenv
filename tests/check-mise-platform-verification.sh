#!/usr/bin/env bash
# Check each supported platform independently; one platform cannot satisfy
# another platform's checksum or provenance requirement.
set -euo pipefail

LOCK=${1:?lockfile required}
if [[ $# -eq 1 ]]; then
    manifest="$(dirname "$0")/mise-expected-verification.toml"
    status=0
    while IFS=$'\t' read -r tool expected; do
        case "$expected" in core|npm|postinstall-gpg) continue ;; esac
        bash "$0" "$LOCK" "$tool" "$expected" || status=1
    done < <(awk -F= '
        /^[[:space:]]*#/ || !/=/{next}
        { key=$1; value=$2; sub(/#.*/, "", value); gsub(/["[:space:]]/, "", key); gsub(/["[:space:]]/, "", value); print key "\t" value }
    ' "$manifest")
    exit "$status"
fi
TOOL=${2:?tool required}
EXPECTED=${3:?verification method required}

case "$TOOL" in
    *[!a-zA-Z0-9_-]*) section="[tools.\"${TOOL}\"." ;;
    *) section="[tools.${TOOL}." ;;
esac

algorithm=${EXPECTED%%+*}
provenance=""
[[ "$EXPECTED" != *+* ]] || provenance=${EXPECTED#*+}
status=0

# TOFU backends can record URL-only placeholders for uninstalled platforms.
# Audit platforms with verification material; do not invent hashes for those
# unresolved assets. Provenance without a checksum still fails below.
platforms=$(awk -v section="$section" '
    /^\[/ {
        platform=""
        if (index($0, section) == 1 && match($0, /"platforms\.[^"]+"/)) {
            platform=substr($0, RSTART+11, RLENGTH-12)
            if ($0 ~ /\.provenance\./) print platform
        }
    }
    platform != "" && /^checksum *=/ { print platform }
' "$LOCK" | sort -u)
if [[ -z "$platforms" ]]; then
    echo "${TOOL}: no platform checksums found" >&2
    exit 1
fi
for platform in $platforms; do
    header="${section}\"platforms.${platform}\""
    signals=$(awk -v header="$header" '
        /^\[/ {
            in_platform = index($0, header "]") == 1 || index($0, header ".") == 1
            if (in_platform && $0 == header "]") print "platform"
            if (in_platform && match($0, /\.provenance\.[a-zA-Z0-9_-]+/)) {
                print "provenance:" substr($0, RSTART+12, RLENGTH-12)
            }
        }
        in_platform && /^checksum *= *"/ {
            if (match($0, /"[^:]+:/)) print "checksum:" substr($0, RSTART+1, RLENGTH-2)
        }
    ' "$LOCK")
    checksums=$(awk -F: '/^checksum:/{print $2}' <<< "$signals")
    if ! grep -qx platform <<< "$signals" || [[ "$checksums" != "$algorithm" ]]; then
        echo "${TOOL}/${platform}: expected one ${algorithm} checksum; found ${checksums:-none}" >&2
        status=1
    fi
    if [[ -n "$provenance" ]] && ! grep -qxF "provenance:${provenance}" <<< "$signals"; then
        echo "${TOOL}/${platform}: missing provenance.${provenance}" >&2
        status=1
    fi
done
exit "$status"
