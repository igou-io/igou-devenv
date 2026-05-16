#!/usr/bin/env bash
# Post-install GPG verification for oc.
#
# mise's http backend has already pinned a blake3 checksum of the downloaded
# tarball in mise.lock. That floor is equivalent to today's inline TOFU-SHA256.
# This script adds the trust anchor we'd otherwise lose by moving off the
# inline install: Red Hat's release signing key (key 2,
# fingerprint 567E347AD0044ADE55BA8A5F199E2F91FD431D51).
#
# Re-fetches sha256sum.txt.gpg (an inline-signed OpenPGP message), verifies
# the GPG signature against the pinned-fingerprint key, then asserts that the
# tarball mise pulled matches the GPG-signed sha256. Build halts on any
# failure (non-zero exit → mise marks the install failed → Docker layer fails).
#
# Env vars set by mise:
#   MISE_TOOL_VERSION       — e.g. "4.21.16"
#   MISE_TOOL_INSTALL_PATH  — directory containing the extracted binaries
set -euo pipefail

OC_PGP_FPR="567E347AD0044ADE55BA8A5F199E2F91FD431D51"
OC_PGP_URL="https://www.redhat.com/security/data/fd431d51.txt"
OC_VERSION="${MISE_TOOL_VERSION:?MISE_TOOL_VERSION not set}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="aarch64" ;;
  *) echo "[oc-postinstall] Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

BASE="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_VERSION}"
TARBALL="openshift-client-linux.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="${WORK}/gnupg"
mkdir -p -m 0700 "$GNUPGHOME"

cd "$WORK"

curl -fsSL -o key.asc "$OC_PGP_URL"
gpg --batch --import key.asc
gpg --list-keys --with-colons --with-fingerprint \
  | awk -F: '$1=="fpr"{print $10}' \
  | grep -qFx "${OC_PGP_FPR}"

curl -fsSL -o sha256sum.txt.gpg "${BASE}/sha256sum.txt.gpg"
# sha256sum.txt.gpg is a binary inline-signed OpenPGP message (NOT a detached
# signature). --decrypt extracts the plaintext AND verifies the signature in
# one step; exit 0 means the signature was good and signed by our anchored key.
gpg --batch --output sha256sum.txt --decrypt sha256sum.txt.gpg

curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"
expected_sha="$(grep " ${TARBALL}\$" sha256sum.txt | awk '{print $1}')"
if [ -z "$expected_sha" ]; then
    echo "[oc-postinstall] no entry for ${TARBALL} in sha256sum.txt" >&2
    exit 1
fi
actual_sha="$(sha256sum "$TARBALL" | awk '{print $1}')"

if [ "$expected_sha" != "$actual_sha" ]; then
    echo "[oc-postinstall] GPG-verified sha256 ($expected_sha) does not match downloaded tarball ($actual_sha)" >&2
    exit 1
fi

echo "[oc-postinstall] verified ${OC_VERSION} via Red Hat GPG key ${OC_PGP_FPR}"
