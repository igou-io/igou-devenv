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

# Prompt: user (env) [depth] ➜ dir (git branch)
__git_branch() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    [ -n "$branch" ] && printf ' (%s)' "$branch"
}
__prompt_env() {
    [ -n "${OP_ENV:-}" ] && printf ' \[\e[1;32m\](%s)\[\e[0m\]' "$OP_ENV"
}
__prompt_depth() {
    [ "${SHLVL:-1}" -gt 1 ] && printf ' \[\e[0;33m\][%s]\[\e[0m\]' "$SHLVL"
}
PS1='$(__prompt_env)$(__prompt_depth) \[\e[1;36m\]\u \[\e[1;33m\]➜ \[\e[1;34m\]\w\[\e[0;35m\]$(__git_branch)\[\e[0m\] $ '

# Auto-heal stale SSH agent sockets (Cursor/VS Code reconnect bug)
_fix_ssh_auth_sock() {
    [ -e "${SSH_AUTH_SOCK:-}" ] && ssh-add -l &>/dev/null && return
    for sock in $(ls -t /tmp/cursor-remote-ssh-auth-*.sock /tmp/vscode-ssh-auth-*.sock /tmp/ssh-*/agent.* 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" ssh-add -l &>/dev/null; then
            export SSH_AUTH_SOCK="$sock"
            return
        fi
    done
}
PROMPT_COMMAND="_fix_ssh_auth_sock${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# 1Password service account token
[ -f ~/.config/op/service-account-token ] && export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)

# Environment switching via 1Password (see adr/0001)
use() {
    local envfile="$HOME/.config/envs/${1}.env"
    if [ ! -f "$envfile" ]; then
        echo "No env file: $envfile"
        echo "Available:"
        ls ~/.config/envs/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//'
        return 1
    fi
    local new_env="${OP_ENV:+${OP_ENV}/}${1}"
    # If env references a kubeconfig, write it to a temp file
    local kubeconfig_ref
    kubeconfig_ref=$(grep '^KUBECONFIG_DATA=' "$envfile" | cut -d= -f2)
    if [ -n "$kubeconfig_ref" ]; then
        local tmpkube
        tmpkube=$(mktemp /tmp/kubeconfig.XXXXXX)
        op read "$kubeconfig_ref" > "$tmpkube"
        OP_ENV="$new_env" KUBECONFIG="$tmpkube" op run --env-file="$envfile" -- bash
        rm -f "$tmpkube"
    else
        OP_ENV="$new_env" op run --env-file="$envfile" -- bash
    fi
}

k8s-unset() {
    unset KUBECONFIG KUBECONFIG_DATA K8S_AUTH_HOST K8S_AUTH_API_KEY K8S_AUTH_VERIFY_SSL
    echo "Kubernetes vars unset"
}

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
        { "path": "igou-devenv" },
        { "path": "rosa-gitops" },
        { "path": "rosa-gitops-example-team" }
    ]
}
EOF
else
    echo "==> CI detected, skipping shell config and workspace file"
fi

echo "==> Setup complete!"
