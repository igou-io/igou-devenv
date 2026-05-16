#!/usr/bin/env bash
# Post-install GPG verification for terraform.
#
# mise's aqua backend already pinned a sha256 of the zip in mise.lock,
# but does NOT verify HashiCorp's GPG signature against the pinned release
# key. This hook restores the inline block's trust chain: pinned-fingerprint
# key → detached signature on SHA256SUMS → SHA256SUMS contains the zip's
# verified hash.
#
# Trust anchor: C874011F0AB405110D02105534365D9472D7468F (HashiCorp key 72D7468F).
#
# Env vars set by mise:
#   MISE_TOOL_VERSION       — e.g. "1.15.0"
#   MISE_TOOL_INSTALL_PATH  — directory containing the extracted binary
set -euo pipefail

TERRAFORM_PGP_FPR="C874011F0AB405110D02105534365D9472D7468F"
TERRAFORM_PGP_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"
TERRAFORM_VERSION="${MISE_TOOL_VERSION:?MISE_TOOL_VERSION not set}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "[terraform-postinstall] Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

ZIP="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"
BASE="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="${WORK}/gnupg"
mkdir -p -m 0700 "$GNUPGHOME"

cd "$WORK"

curl -fsSL -o key.asc "$TERRAFORM_PGP_URL"
gpg --batch --import key.asc
gpg --list-keys --with-colons --with-fingerprint \
  | awk -F: '$1=="fpr"{print $10}' \
  | grep -qFx "${TERRAFORM_PGP_FPR}"

curl -fsSL -o SHA256SUMS     "${BASE}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
curl -fsSL -o SHA256SUMS.sig "${BASE}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"
gpg --batch --verify SHA256SUMS.sig SHA256SUMS

curl -fsSL -o "$ZIP" "${BASE}/${ZIP}"
expected_sha="$(grep " ${ZIP}\$" SHA256SUMS | awk '{print $1}')"
if [ -z "$expected_sha" ]; then
    echo "[terraform-postinstall] no entry for ${ZIP} in SHA256SUMS" >&2
    exit 1
fi
actual_sha="$(sha256sum "$ZIP" | awk '{print $1}')"

if [ "$expected_sha" != "$actual_sha" ]; then
    echo "[terraform-postinstall] GPG-verified sha256 ($expected_sha) does not match downloaded zip ($actual_sha)" >&2
    exit 1
fi

echo "[terraform-postinstall] verified ${TERRAFORM_VERSION} via HashiCorp GPG key ${TERRAFORM_PGP_FPR}"
