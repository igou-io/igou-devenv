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
    cp /workspace/igou-devenv/dotfiles/tmux.conf /home/igou/.tmux.conf

    echo "==> Writing workspace file..."
    cp /workspace/igou-devenv/dotfiles/homelab.code-workspace /workspace/homelab.code-workspace

    # Seed the code-server config only if absent — ~/.config/code-server is a
    # persistent bind mount, so an existing config (with its generated password
    # and any user edits) must survive rebuilds rather than be overwritten.
    echo "==> Installing code-server config (first run only)..."
    mkdir -p /home/igou/.config/code-server
    if [ ! -f /home/igou/.config/code-server/config.yaml ]; then
        cp /workspace/igou-devenv/dotfiles/code-server-config.yaml /home/igou/.config/code-server/config.yaml
    fi

    # GitHub App runtime tokens (ghapp): seed the per-user config — only if
    # absent, like the code-server config above. On a fresh laptop/devhost
    # container ~/.config/ghapp is container-local and empty, so the op-based
    # dotfiles config is seeded exactly as before. On hosts that bind-mount a
    # pre-existing config into the container (the headless devenv VM mounts
    # its file-based, private_key_path config read-only at this path), the
    # mounted config wins and an unconditional cp would fail on the read-only
    # mount. Non-secret either way (IDs only); the private key is read from
    # 1Password (op-based) or the mounted key.pem (file-based) at mint time.
    # GHAPP_CONFIG (in .bashrc) points the CLI + git credential helper here.
    echo "==> Installing ghapp config (GitHub App runtime tokens, first run only)..."
    mkdir -p /home/igou/.config/ghapp
    if [ ! -f /home/igou/.config/ghapp/config.yaml ]; then
        cp /workspace/igou-devenv/dotfiles/ghapp/config.yaml /home/igou/.config/ghapp/config.yaml
        chmod 600 /home/igou/.config/ghapp/config.yaml
    fi
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

# ---------------------------------------------------------------------------
# Expose the shared Claude skills to other agents that look in ~/.agents/skills.
# ~/.claude persists (bind mount → host ~/.claude-container), but ~/.agents is
# on the ephemeral container fs, so the symlink must be recreated each build.
# ---------------------------------------------------------------------------
mkdir -p /home/igou/.agents
ln -sfn /home/igou/.claude/skills /home/igou/.agents/skills

echo "==> Setup complete!"
