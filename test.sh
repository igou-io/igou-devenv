#!/usr/bin/env bash
# Test the devcontainer image build and verify installed tools.
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
    op
)

BINARY_TOOLS=(
    argocd
    kustomize
    kubeseal
    flux
    sops
    oc
    virtctl
)

PASS=0
FAIL=0

for tool in "${APT_TOOLS[@]}" "${BINARY_TOOLS[@]}"; do
    if podman run --rm "$IMAGE" which "$tool" &>/dev/null; then
        echo "  [OK] $tool"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $tool not found"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "==> Results: $PASS passed, $FAIL failed"

podman rmi "$IMAGE" &>/dev/null

[[ "$FAIL" -eq 0 ]]
