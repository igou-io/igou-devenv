#!/usr/bin/env bash
# Run all test suites. Used by both `make test` (via devcontainer exec)
# and CI (via devcontainers/ci runCmd).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  test-tools"
echo "========================================="
"$DIR/test-tools.sh"

echo ""
echo "========================================="
echo "  test-podman"
echo "========================================="
"$DIR/test-podman.sh"

echo ""
echo "========================================="
echo "  test-env"
echo "========================================="
# test-env requires interactive shell for .bashrc functions
bash -i "$DIR/test-env.sh"

echo ""
echo "========================================="
echo "  All tests passed"
echo "========================================="
