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
    if check "${3:-sha256+slsa}" > "$WORK/output" 2>&1; then
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

# Lock generation and installation can use different strong digest formats
# for TOFU assets. Neither algorithm implies an upstream signature.
printf -v digest '%064d' 0
cat > "$WORK/mise.lock" <<EOF
[[tools.flux2]]
version = "2.9.6"
[tools.flux2."platforms.linux-x64"]
checksum = "sha256:$digest"
[tools.flux2."platforms.linux-arm64"]
checksum = "blake3:$digest"
EOF
cp "$WORK/mise.lock" "$WORK/tofu.lock"
check tofu
reject 'TOFU pin replacing required SLSA' 'flux2/linux-x64: missing provenance.slsa'
sed -i '/checksum/a checksum = "sha256:duplicate"' "$WORK/mise.lock"
reject 'duplicate TOFU checksum' 'flux2/linux-arm64: expected one tofu checksum' tofu
cp "$WORK/tofu.lock" "$WORK/mise.lock"
sed -i '/checksum/s/"$/:extra"/' "$WORK/mise.lock"
reject 'trailing TOFU digest data' 'flux2/linux-arm64: expected one tofu checksum' tofu
cp "$WORK/tofu.lock" "$WORK/mise.lock"
sed -i 's/blake3:/sha1:/' "$WORK/mise.lock"
reject 'weak TOFU checksum' 'flux2/linux-arm64: expected one tofu checksum; found sha1' tofu
sed -i 's/sha1:/sha256:/; s/sha256:0/sha256:/' "$WORK/mise.lock"
reject 'malformed TOFU digest' 'flux2/linux-arm64: expected one tofu checksum; found sha256' tofu
sed -i '/checksum/d' "$WORK/mise.lock"
reject 'missing TOFU pins' 'flux2: no platform checksums found' tofu
echo '[OK] TOFU accepts strong digest formats and rejects weak, malformed, and absent pins'
