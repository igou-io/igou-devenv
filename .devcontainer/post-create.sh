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

# 1Password service account token (skip in Cursor agent shells)
if [ -z "${CURSOR_AGENT:-}" ] && [ -f ~/.config/op/service-account-token ]; then
    export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)
fi

# Environment switching via 1Password (see adr/0001)
# Resolves op:// secrets via "op inject" and exports them in the current shell.
# Use unuse() to remove an environment's variables.
_use_sanitize() { echo "${1//-/_}"; }

# Clean up all temp kubeconfig files on shell exit
_use_cleanup_all() {
    local varname
    while IFS='=' read -r varname _; do
        [[ "$varname" == _USE_TMPKUBE_* ]] && rm -f "${!varname}"
    done < <(env)
}
trap _use_cleanup_all EXIT

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
    local safe_name
    safe_name=$(_use_sanitize "$1")

    # Parse kubeconfig strategy from env file. Three mutually exclusive approaches:
    #   KUBECONFIG_DATA  — base64-encoded full kubeconfig (op read + decode)
    #   KUBECONFIG_TOKEN + KUBECONFIG_HOST — dynamically build a kubeconfig from token/host
    # Both present is an error.
    local kubeconfig_data_ref kubeconfig_token_ref kubeconfig_host_ref
    kubeconfig_data_ref=$(grep '^KUBECONFIG_DATA=' "$envfile" | cut -d= -f2)
    kubeconfig_token_ref=$(grep '^KUBECONFIG_TOKEN=' "$envfile" | cut -d= -f2)
    kubeconfig_host_ref=$(grep '^KUBECONFIG_HOST=' "$envfile" | cut -d= -f2)

    if [ -n "$kubeconfig_data_ref" ] && { [ -n "$kubeconfig_token_ref" ] || [ -n "$kubeconfig_host_ref" ]; }; then
        echo "Error: ${1}.env has both KUBECONFIG_DATA and KUBECONFIG_TOKEN/KUBECONFIG_HOST — use one or the other"
        return 1
    fi
    if { [ -n "$kubeconfig_token_ref" ] && [ -z "$kubeconfig_host_ref" ]; } || \
       { [ -z "$kubeconfig_token_ref" ] && [ -n "$kubeconfig_host_ref" ]; }; then
        echo "Error: ${1}.env must have both KUBECONFIG_TOKEN and KUBECONFIG_HOST (found only one)"
        return 1
    fi

    # Resolve op:// references via op inject (one-shot, no wrapper process).
    # Kubeconfig-related keys are handled separately — strip them before op inject.
    local remaining
    remaining=$(grep -v '^KUBECONFIG_DATA=\|^KUBECONFIG_TOKEN=\|^KUBECONFIG_HOST=' "$envfile")

    local keys=()
    if [ -n "$remaining" ]; then
        local resolved
        resolved=$(echo "$remaining" | op inject) || {
            echo "Failed to resolve secrets for ${1}"
            return 1
        }
        local key value
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            key="${line%%=*}"
            value="${line#*=}"
            export "$key=$value"
            keys+=("$key")
        done <<< "$resolved"
    fi

    if [ -n "$kubeconfig_data_ref" ] || [ -n "$kubeconfig_token_ref" ]; then
        # Clean up previous temp kubeconfig for this env if re-using
        local tmpvar="_USE_TMPKUBE_${safe_name}"
        [ -n "${!tmpvar:-}" ] && rm -f "${!tmpvar}"
        local tmpkube
        tmpkube=$(mktemp /tmp/kubeconfig.XXXXXX)

        if [ -n "$kubeconfig_data_ref" ]; then
            # Full kubeconfig from 1Password (base64-encoded)
            op read "$kubeconfig_data_ref" | base64 -d > "$tmpkube"
        else
            # Build kubeconfig from token + host
            local kube_token kube_host
            kube_token=$(echo "$kubeconfig_token_ref" | op inject)
            kube_host=$(echo "$kubeconfig_host_ref" | op inject)
            cat > "$tmpkube" << KUBECFG
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${kube_host}
    insecure-skip-tls-verify: true
  name: cluster
contexts:
- context:
    cluster: cluster
    user: user
  name: context
current-context: context
users:
- name: user
  user:
    token: ${kube_token}
KUBECFG
        fi

        export KUBECONFIG="$tmpkube"
        keys+=("KUBECONFIG")
        export "$tmpvar=$tmpkube"
    fi

    # Track which keys this env set (for unuse)
    local keys_var="_USE_KEYS_${safe_name}"
    # shellcheck disable=SC2178
    export "$keys_var=${keys[*]}"

    # Update tracking: OP_ENV shows last-used env, OP_ENV_LIST tracks all active
    export OP_ENV="$1"
    if [[ ",${OP_ENV_LIST:-}," != *",${1},"* ]]; then
        export OP_ENV_LIST="${OP_ENV_LIST:+${OP_ENV_LIST},}${1}"
    fi

    echo "Environment '${1}' activated"
}

unuse() {
    if [ -z "${1:-}" ]; then
        # Unuse all active environments
        if [ -z "${OP_ENV_LIST:-}" ]; then
            return 0
        fi
        local env_name
        for env_name in ${OP_ENV_LIST//,/ }; do
            unuse "$env_name"
        done
        return 0
    fi

    # Idempotent: if env is not active, nothing to do
    if [[ ",${OP_ENV_LIST:-}," != *",${1},"* ]]; then
        return 0
    fi

    local safe_name
    safe_name=$(_use_sanitize "$1")

    # Unset tracked variables
    local keys_var="_USE_KEYS_${safe_name}"
    if [ -n "${!keys_var:-}" ]; then
        local key
        for key in ${!keys_var}; do
            unset "$key"
        done
        unset "$keys_var"
    fi

    # Clean up temp kubeconfig
    local tmpvar="_USE_TMPKUBE_${safe_name}"
    if [ -n "${!tmpvar:-}" ]; then
        rm -f "${!tmpvar}"
        unset "$tmpvar"
    fi

    # Update OP_ENV_LIST: remove this env
    local new_list="" env_name
    for env_name in ${OP_ENV_LIST//,/ }; do
        [ "$env_name" = "$1" ] && continue
        new_list="${new_list:+${new_list},}${env_name}"
    done
    if [ -n "$new_list" ]; then
        export OP_ENV_LIST="$new_list"
        # Set OP_ENV to the last remaining env
        export OP_ENV="${new_list##*,}"
    else
        unset OP_ENV OP_ENV_LIST
    fi

    echo "Environment '${1}' deactivated"
}

k8s-unset() {
    unset KUBECONFIG KUBECONFIG_DATA K8S_AUTH_HOST K8S_AUTH_API_KEY K8S_AUTH_VERIFY_SSL
    echo "Kubernetes vars unset"
}

ansible-unset() {
    while IFS='=' read -r name _; do
        [[ "$name" == ANSIBLE_* ]] && unset "$name"
    done < <(env)
    echo "Ansible vars unset"
}

# Cursor/VS Code shell integration.
# Cache the resolved path to avoid re-running CLI discovery on every terminal.
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
    if [ -z "${VSCODE_SHELL_INTEGRATION_PATH:-}" ]; then
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
