#!/usr/bin/env bash
# Runs once after container creation. Handles workspace setup.
# Repos are expected to be pre-cloned on the host at ~/workspace and
# bind-mounted into the container.
set -euo pipefail

# ---------------------------------------------------------------------------
# Shell configuration and workspace file — skipped in CI
# ---------------------------------------------------------------------------
if [ -z "${CI:-}" ]; then
    echo "==> Configuring shell..."
    cp /workspace/igou-devenv/dotfiles/.bashrc /home/igou/.bashrc

    echo "==> Writing workspace file..."
    cp /workspace/igou-devenv/dotfiles/homelab.code-workspace /workspace/homelab.code-workspace
else
    echo "==> CI detected, skipping shell config and workspace file"
fi

# ---------------------------------------------------------------------------
# Cursor sandbox config — grant agent access to bind-mounted paths
# ---------------------------------------------------------------------------
echo "==> Writing Cursor sandbox config..."
mkdir -p /workspace/.cursor
cat > /workspace/.cursor/sandbox.json << 'EOF'
{
  "networkPolicy": {
    "default": "allow"
  }
}
EOF

# ---------------------------------------------------------------------------
# Symlink bin/ scripts into ~/bin (already on PATH via .bashrc)
# ---------------------------------------------------------------------------
ln -sfn /workspace/igou-devenv/bin /home/igou/bin

echo "==> Setup complete!"
