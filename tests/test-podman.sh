#!/usr/bin/env bash
# Test podman pull, run, and build inside the devcontainer.
set -euo pipefail

echo "==> podman pull..."
podman pull docker.io/library/alpine:latest

echo "==> podman run..."
podman run --rm docker.io/library/alpine:latest echo "hello from podman"

echo "==> podman build..."
TMP=$(mktemp -d)
echo "FROM docker.io/library/alpine:latest" > "$TMP/Containerfile"
podman build -t podman-test:local "$TMP"
podman rmi -f podman-test:local docker.io/library/alpine:latest
rm -rf "$TMP"

echo "==> All podman tests passed"
