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

    cat >> /home/igou/.bashrc << 'BASHRC'

# --- igou-io devenv config ---
export ANSIBLE_INVENTORY=/workspace/igou-inventory
export ANSIBLE_HOST_KEY_CHECKING=False
export PATH=$PATH:/home/igou/.local/bin:/home/igou/bin

# Prompt: user ➜ dir (git branch)
__git_branch() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    [ -n "$branch" ] && printf ' (%s)' "$branch"
}
PS1='\[\e[1;36m\]\u \[\e[1;33m\]➜ \[\e[1;34m\]\w\[\e[0;35m\]$(__git_branch)\[\e[0m\] $ '

# Aliases
alias k=kubectl

# direnv
eval "$(direnv hook bash)"
BASHRC

    echo "==> Writing workspace file..."
    cat > /workspace/homelab.code-workspace << 'EOF'
{
    "folders": [
        { "path": "igou-ansible" },
        { "path": "igou-inventory" },
        { "path": "igou-kubernetes" },
        { "path": "igou-kubernetes-private" },
        { "path": "igou-infrastructure" },
        { "path": "igou-openshift" },
        { "path": "igou-containers" },
        { "path": "igou-devenv" }
    ]
}
EOF
else
    echo "==> CI detected, skipping shell config and workspace file"
fi

echo "==> Setup complete!"
