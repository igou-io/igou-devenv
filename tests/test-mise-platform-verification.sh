#!/usr/bin/env bash
# Regression for a green x64 entry masking missing ARM64 SLSA provenance.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/mise.lock" <<'EOF'
[[tools.flux2]]
version = "2.9.6"
[tools.flux2."platforms.linux-x64"]
checksum = "sha256:x64"
[tools.flux2."platforms.linux-x64".provenance.slsa]
url = "https://example.test/provenance"
[tools.flux2."platforms.linux-arm64"]
checksum = "sha256:arm64"
EOF

check() { bash "$REPO/tests/check-mise-platform-verification.sh" "$WORK/mise.lock" flux2 "$1"; }
reject() {
    if check sha256+slsa > "$WORK/output" 2>&1; then
        echo "[FAIL] accepted $1" >&2
        exit 1
    fi
    grep -qF "$2" "$WORK/output"
}

reject 'missing ARM64 provenance' 'flux2/linux-arm64: missing provenance.slsa'
check sha256
cat >> "$WORK/mise.lock" <<'EOF'
[tools.flux2."platforms.linux-arm64".provenance.slsa]
url = "https://example.test/provenance"
EOF
check sha256+slsa
sed 's/tools.flux2/tools."aqua:demo\/tool"/g' "$WORK/mise.lock" > "$WORK/quoted.lock"
bash "$REPO/tests/check-mise-platform-verification.sh" "$WORK/quoted.lock" aqua:demo/tool sha256+slsa
sed -i 's/sha256:arm64/blake3:arm64/' "$WORK/mise.lock"
reject 'ARM64 checksum downgrade' 'flux2/linux-arm64: expected one sha256 checksum; found blake3'
sed -i '/platforms.linux-arm64/,$d' "$WORK/mise.lock"
sed -i '/checksum/d' "$WORK/mise.lock"
reject 'missing platform checksum' 'flux2/linux-x64: expected one sha256 checksum; found none'
printf '[[tools.flux2]]\nversion = "2.9.6"\n' > "$WORK/mise.lock"
reject 'missing verification material' 'flux2: no platform checksums found'
echo '[OK] per-platform verification rejects missing provenance, downgraded checksums, and absent checksums'
