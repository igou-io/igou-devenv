#!/usr/bin/env bash
# Test the devcontainer image build and verify apt-installed tools.
# Note: devcontainer Features (kubectl, helm, terraform, etc.) are applied by
# Cursor/the devcontainer CLI at open time and are not tested here.
set -euo pipefail

IMAGE="igou-devenv-test:local"

echo "==> Building image..."
podman build -f .devcontainer/Dockerfile .devcontainer/ -t "$IMAGE"

echo ""
echo "==> Running tool checks inside container..."

APT_TOOLS=(
    podman
    buildah
    skopeo
    jq
    direnv
    shellcheck
    make
    sshpass
    age
    gpg
    tree
    ssh
)

PASS=0
FAIL=0

for tool in "${APT_TOOLS[@]}"; do
    if podman run --rm "$IMAGE" which "$tool" &>/dev/null; then
        echo "  [OK] $tool"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $tool not found"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "==> Checking /workspace directory exists and is owned by vscode..."
OWNER=$(podman run --rm "$IMAGE" stat -c '%U' /workspace)
if [[ "$OWNER" == "vscode" ]]; then
    echo "  [OK] /workspace owned by vscode"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] /workspace owned by $OWNER (expected vscode)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"

podman rmi "$IMAGE" &>/dev/null

[[ "$FAIL" -eq 0 ]]
