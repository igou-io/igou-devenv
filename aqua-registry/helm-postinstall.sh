#!/usr/bin/env bash
# Post-install GPG verification for helm.
#
# mise's aqua backend already pinned a sha256 of the tarball in mise.lock,
# but does NOT verify Helm's GPG signature against the pinned release key.
# This hook restores the inline block's trust chain: pinned-fingerprint key
# → detached signature on tarball → tarball matches what mise extracted.
#
# Trust anchor: BF888333D96A1C18E2682AAED79D67C9EC016739 (helm release key).
#
# Env vars set by mise:
#   MISE_TOOL_VERSION       — e.g. "4.1.4" (NO leading 'v')
#   MISE_TOOL_INSTALL_PATH  — directory containing the extracted binaries
set -euo pipefail

HELM_PGP_FPR="BF888333D96A1C18E2682AAED79D67C9EC016739"
HELM_KEYS_URL="https://raw.githubusercontent.com/helm/helm/main/KEYS"
HELM_VERSION="${MISE_TOOL_VERSION:?MISE_TOOL_VERSION not set}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "[helm-postinstall] Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

TARBALL="helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"
TARBALL_URL="https://get.helm.sh/${TARBALL}"
ASC_URL="https://github.com/helm/helm/releases/download/v${HELM_VERSION}/${TARBALL}.asc"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="${WORK}/gnupg"
mkdir -p -m 0700 "$GNUPGHOME"

cd "$WORK"

curl -fsSL -o key.asc "$HELM_KEYS_URL"
gpg --batch --import key.asc
gpg --list-keys --with-colons --with-fingerprint \
  | awk -F: '$1=="fpr"{print $10}' \
  | grep -qFx "${HELM_PGP_FPR}"

curl -fsSL -o "$TARBALL"       "$TARBALL_URL"
curl -fsSL -o "${TARBALL}.asc" "$ASC_URL"

# Detached signature: the .asc signs the tarball directly. gpg --verify exits
# 0 only on a good signature from a key in our anchored keyring.
gpg --batch --verify "${TARBALL}.asc" "$TARBALL"

echo "[helm-postinstall] verified ${HELM_VERSION} via Helm GPG key ${HELM_PGP_FPR}"
