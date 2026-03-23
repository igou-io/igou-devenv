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

# Prompt: user (env) ➜ dir (git branch)
__prompt_command() {
    local exit_code=$?
    local reset='\e[0m' cyan='\e[1;36m' yellow='\e[1;33m' blue='\e[1;34m' purple='\e[0;35m' green='\e[1;32m'
    local env_info=""
    if [ -n "${OP_ENV:-}" ]; then
        env_info=" \[$green\](${OP_ENV})\[$reset\]"
    fi
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    local git_info=""
    [ -n "$branch" ] && git_info=" \[$purple\]($branch)\[$reset\]"
    PS1="\[$cyan\]\u${env_info} \[$yellow\]➜ \[$blue\]\w${git_info}\[$reset\] \$ "
    return $exit_code
}
PROMPT_COMMAND="__prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# Auto-heal stale SSH agent sockets (Cursor/VS Code reconnect bug).
# Uses timeout to prevent hanging on broken sockets in use() subshells.
_fix_ssh_auth_sock() {
    [ -e "${SSH_AUTH_SOCK:-}" ] && timeout 2 ssh-add -l &>/dev/null && return
    for sock in $(ls -t /tmp/cursor-remote-ssh-auth-*.sock /tmp/vscode-ssh-auth-*.sock /tmp/ssh-*/agent.* 2>/dev/null); do
        if SSH_AUTH_SOCK="$sock" timeout 2 ssh-add -l &>/dev/null; then
            export SSH_AUTH_SOCK="$sock"
            return
        fi
    done
}
PROMPT_COMMAND="_fix_ssh_auth_sock${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# 1Password service account token
[ -f ~/.config/op/service-account-token ] && export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)

# Environment switching via 1Password (see adr/0001)
# Uses "op inject" to resolve secrets then spawns bash via env, avoiding
# "op run" as a process wrapper — nested op run deadlocks.
use() {
    local envdir="/workspace/igou-devenv/envs"
    if [ -z "${1:-}" ]; then
        echo "Available environments:"
        ls "${envdir}"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//'
        return 0
    fi
    local envfile="${envdir}/${1}.env"
    if [ ! -f "$envfile" ]; then
        echo "No env file: $envfile"
        echo "Available:"
        ls "${envdir}"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//'
        return 1
    fi
    # Prevent stacking the same env twice (e.g. aws/aws/aws)
    if [[ ",${OP_ENV_LIST:-}," == *",${1},"* ]]; then
        echo "Environment '${1}' is already active"
        return 1
    fi
    # If env references a kubeconfig, block if one is already active
    local kubeconfig_ref
    kubeconfig_ref=$(grep '^KUBECONFIG_DATA=' "$envfile" | cut -d= -f2)
    if [ -n "$kubeconfig_ref" ] && [ -n "${KUBECONFIG:-}" ]; then
        echo "A kubeconfig environment is already active (${OP_ENV})"
        echo "Exit the current environment first, or use k8s-unset"
        return 1
    fi
    local new_env="${OP_ENV:+${OP_ENV}/}${1}"
    local new_list="${OP_ENV_LIST:+${OP_ENV_LIST},}${1}"

    # Resolve op:// references via op inject (one-shot, no wrapper process).
    # Skip op inject if the env file only contained KUBECONFIG_DATA.
    local remaining
    remaining=$(grep -v '^KUBECONFIG_DATA=' "$envfile")

    local env_args=("OP_ENV=$new_env" "OP_ENV_LIST=$new_list")
    if [ -n "$remaining" ]; then
        local resolved
        resolved=$(echo "$remaining" | op inject) || {
            echo "Failed to resolve secrets for ${1}"
            return 1
        }
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            env_args+=("$line")
        done <<< "$resolved"
    fi

    if [ -n "$kubeconfig_ref" ]; then
        local tmpkube
        tmpkube=$(mktemp /tmp/kubeconfig.XXXXXX)
        op read "$kubeconfig_ref" | base64 -d > "$tmpkube"
        env_args+=("KUBECONFIG=$tmpkube")
        env "${env_args[@]}" bash
        rm -f "$tmpkube"
    else
        env "${env_args[@]}" bash
    fi
}

k8s-unset() {
    unset KUBECONFIG KUBECONFIG_DATA K8S_AUTH_HOST K8S_AUTH_API_KEY K8S_AUTH_VERIFY_SSL
    echo "Kubernetes vars unset"
}

# Re-enable Cursor/VS Code shell integration in subshells (use() spawns child bash).
# The cursor/code CLI can hang in subshells, so we cache the resolved path to a
# file and only run CLI discovery in the top-level shell (no OP_ENV set).
# Set BASHRC_DEBUG=1 to trace shell startup (useful for diagnosing hangs).
if [ -n "${BASHRC_DEBUG:-}" ]; then
    echo "[bashrc] starting shell integration block" >&2
fi
if [ "$TERM_PROGRAM" = "vscode" ]; then
    _vsi_cache="/tmp/.vscode-shell-integration-path"
    if [ -z "${VSCODE_SHELL_INTEGRATION_PATH:-}" ] && [ -f "$_vsi_cache" ]; then
        VSCODE_SHELL_INTEGRATION_PATH=$(cat "$_vsi_cache")
        export VSCODE_SHELL_INTEGRATION_PATH
    fi
    if [ -z "${VSCODE_SHELL_INTEGRATION_PATH:-}" ] && [ -z "${OP_ENV:-}" ]; then
        for _cmd in cursor code; do
            VSCODE_SHELL_INTEGRATION_PATH=$($_cmd --locate-shell-integration-path bash 2>/dev/null) && break
        done
        export VSCODE_SHELL_INTEGRATION_PATH
        [ -n "${VSCODE_SHELL_INTEGRATION_PATH:-}" ] && echo "$VSCODE_SHELL_INTEGRATION_PATH" > "$_vsi_cache"
        unset _cmd
    fi
    [ -n "${VSCODE_SHELL_INTEGRATION_PATH:-}" ] && . "$VSCODE_SHELL_INTEGRATION_PATH"
    unset _vsi_cache
fi
if [ -n "${BASHRC_DEBUG:-}" ]; then
    echo "[bashrc] shell integration done, starting direnv" >&2
fi

# Aliases
alias k=kubectl

# direnv
eval "$(direnv hook bash)"
if [ -n "${BASHRC_DEBUG:-}" ]; then
    echo "[bashrc] direnv done, bashrc complete" >&2
fi
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

# ---------------------------------------------------------------------------
# Symlink bin/ scripts into ~/bin (already on PATH via .bashrc)
# ---------------------------------------------------------------------------
ln -sfn /workspace/igou-devenv/bin /home/igou/bin

echo "==> Setup complete!"
