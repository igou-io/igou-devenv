#!/usr/bin/env bash
# Runs once after container creation. Handles workspace setup that requires
# mounts and SSH agent to be available.
set -euo pipefail

# ---------------------------------------------------------------------------
# Clone repos via SSH (requires agent forwarding) — skipped in CI
# ---------------------------------------------------------------------------
if [ -z "${CI:-}" ]; then
    echo "==> Cloning igou-io repos into /workspace..."

    # Add GitHub to global known_hosts to avoid interactive prompts.
    # ~/.ssh is bind-mounted read-only, so write to the system-wide file instead.
    ssh-keyscan -t ed25519,rsa github.com 2>/dev/null | sudo tee -a /etc/ssh/ssh_known_hosts > /dev/null

    REPOS=(
        "igou-io/igou-kubernetes"
        "igou-io/igou-ansible"
        "igou-io/igou-infrastructure"
        "igou-io/igou-openshift"
        "igou-io/igou-containers"
        # Private repos — require SSH agent forwarding
        "igou-io/igou-inventory"
        "igou-io/igou-kubernetes-private"
    )
    for repo in "${REPOS[@]}"; do
        name=$(basename "$repo")
        if [ ! -d "/workspace/${name}" ]; then
            echo "    Cloning ${repo}..."
            git clone "git@github.com:${repo}.git" "/workspace/${name}" || echo "    WARNING: Failed to clone ${repo} (is your SSH key forwarded?)"
        else
            echo "    ${name} already exists, skipping"
        fi
    done
else
    echo "==> CI detected, skipping repo cloning"
fi

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
