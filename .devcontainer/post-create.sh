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
    mkdir -p /home/igou/.bashrc.d
    cp /workspace/igou-devenv/dotfiles/.bashrc.d/*.sh /home/igou/.bashrc.d/
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
# Point every harness (Claude Code, Codex, OpenCode, Cursor) at the central
# skills repo in /workspace/igou-skills. ~/.agents is on the ephemeral
# container fs, so this must run on every build; ~/.claude persists but the
# script is idempotent.
# ---------------------------------------------------------------------------
/workspace/igou-devenv/bin/link-skills

# ---------------------------------------------------------------------------
# Per-profile opencode shims for scoped t3 instances (adr/0006). t3 keeps one
# shared `opencode serve` per binaryPath, so each profile needs its own
# binary; ~/.local/bin is ephemeral, so regenerate on every build. One shim per
# env profile that carries a kubeconfig or is an INCLUDE= bundle of profiles
# (e.g. read-only) — the ones worth an instance.
#
# The agent images live in the rootless podman store, which is also ephemeral:
# after a rebuild the first t3 probe of every scoped instance had to `podman
# pull` inside t3's 4-10 s probe timeout and showed "Unavailable" until the
# pull happened to complete. Warm the store in the background instead.
# ---------------------------------------------------------------------------
if [ -x /home/igou/.local/bin/agent-sandbox-launch ]; then
    for envfile in /workspace/igou-devenv/envs/*.env; do
        grep -qE '^(KUBECONFIG_(DATA|TOKEN)|INCLUDE)=' "$envfile" || continue
        /home/igou/.local/bin/agent-sandbox-launch --install-shim "$(basename "$envfile" .env)" 2>/dev/null || true
    done
    if command -v podman >/dev/null 2>&1; then
        echo "==> Pre-pulling agent sandbox images in the background (~/.local/share/containers/agent-image-pull.log)"
        mkdir -p /home/igou/.local/share/containers
        (for img in claude-code codex opencode; do
            podman pull "ghcr.io/igou-io/${img}:latest"
        done) > /home/igou/.local/share/containers/agent-image-pull.log 2>&1 &
        disown || true
    fi
fi

echo "==> Setup complete!"
