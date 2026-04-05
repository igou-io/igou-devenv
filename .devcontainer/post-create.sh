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

    # Insert early — before the non-interactive guard so it runs in all shells
    # (including non-interactive Cursor agent shells).
    #
    # CURSOR_AGENT_UNSET_VARS: variables to strip from Cursor agent shells.
    # Add entries here to prevent the agent from accessing sensitive tokens.
    CURSOR_AGENT_UNSET_VARS=(
        OP_SERVICE_ACCOUNT_TOKEN
        SSH_AUTH_SOCK
    )

    unset_block=""
    for var in "${CURSOR_AGENT_UNSET_VARS[@]}"; do
        unset_block+="    unset ${var}\n"
    done

    sed -i '/^case \$- in/i \
# Sensitive variables — unset in Cursor agent shells\
if [ -n "${CURSOR_AGENT:-}" ]; then\
'"$(printf '%s' "$unset_block")"'\
elif [ -f ~/.config/op/service-account-token ]; then\
    export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)\
fi\
' /home/igou/.bashrc

    cat /workspace/igou-devenv/dotfiles/bashrc >> /home/igou/.bashrc

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
