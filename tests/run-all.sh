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

if [ -z "${CI:-}" ]; then
    echo ""
    echo "========================================="
    echo "  test-env"
    echo "========================================="
    # test-env requires interactive shell for .bashrc functions
    # Skipped in CI — post-create.sh only configures shell outside CI
    bash -i "$DIR/test-env.sh"
else
    echo ""
    echo "========================================="
    echo "  test-env (skipped in CI)"
    echo "========================================="
fi

echo ""
echo "========================================="
echo "  test-run-scripts"
echo "========================================="
bash "$DIR/test-run-scripts.sh"

echo ""
echo "========================================="
echo "  test-pinned-versions"
echo "========================================="
"$DIR/test-pinned-versions.sh"

echo ""
echo "========================================="
echo "  test-mise-lockfile (host)"
echo "========================================="
bash "$DIR/test-mise-lockfile.sh"

echo ""
echo "========================================="
echo "  test-mise (in-container)"
echo "========================================="
"$DIR/test-mise.sh"

echo ""
echo "========================================="
echo "  All tests passed"
echo "========================================="
