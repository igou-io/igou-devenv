#!/usr/bin/env bash
# CentOS/RHEL do not yet provide Python 3.15 RPMs. Keep distro Python intact.
set -euo pipefail

# Source and checksum: https://www.python.org/downloads/release/python-3150/
# renovate: datasource=python-version depName=python versioning=pep440
PYTHON_VERSION="3.15.0"
PYTHON_SHA256="ba4bed1ba346b916890b76d9e320451420aa69f6408997d33c66482eeae3d575"

package_manager=${1:?Usage: install-python.sh /usr/bin/dnf-or-microdnf}
shift
# Extra packages are distro-specific; public UBI9 has no readline-devel.
"$package_manager" install -y \
    gcc make tar xz findutils pkgconf-pkg-config \
    openssl-devel bzip2-devel libffi-devel xz-devel zlib-devel \
    sqlite-devel libuuid-devel libzstd-devel "$@"

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
curl -fsSL --retry 3 \
    "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
    -o "$build_dir/python.tar.xz"
printf '%s  %s\n' "$PYTHON_SHA256" "$build_dir/python.tar.xz" | sha256sum --check --strict
tar -xJf "$build_dir/python.tar.xz" -C "$build_dir" --strip-components=1
cd "$build_dir"
./configure --prefix=/usr/local --with-ensurepip=install
# Avoid exhausting memory on builders which report the host's CPU count.
make -j4
make altinstall

ln -sf /usr/local/bin/python3.15 /usr/local/bin/python3
ln -sf /usr/local/bin/python3.15 /usr/local/bin/python
ln -sf /usr/local/bin/pip3.15 /usr/local/bin/pip3
ln -sf /usr/local/bin/pip3.15 /usr/local/bin/pip
python3.15 -c 'import bz2, ctypes, lzma, sqlite3, ssl, zlib; from compression import zstd'
"$package_manager" clean all
