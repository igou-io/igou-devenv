# shellcheck shell=bash
# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# Sensitive variables — unset in Cursor agent shells
# I'm not sure if this actually works
if [ -n "${CURSOR_AGENT:-}" ]; then
    unset OP_SERVICE_ACCOUNT_TOKEN
    unset OP_CONNECT_TOKEN
    unset SSH_AUTH_SOCK
fi

export PATH=$PATH:/home/igou/.local/bin:/home/igou/bin

# GitHub App runtime tokens (ghapp). Point the CLI + git credential helper at the
# per-user config seeded by post-create.sh. Exported unconditionally (not just for
# interactive shells) so `git`'s ghapp credential helper finds the config when git
# is invoked from scripts. The App private key is never on disk here — it is read
# from 1Password at mint time (config's private_key_cmd), so tokens are repo-scoped
# and expire within the hour. See README "GitHub Authentication (ghapp)".
export GHAPP_CONFIG="$HOME/.config/ghapp/config.yaml"

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# 1Password auth. Prefer Connect (self-hosted, no service-account API rate
# limit); fall back to the service-account token when Connect creds are absent.
# All files are bind-mounted read-only from the host's ~/.config/op.
if [ -f ~/.config/op/connect-host ] && [ -f ~/.config/op/connect-token ]; then
    export OP_CONNECT_HOST=$(cat ~/.config/op/connect-host)
    export OP_CONNECT_TOKEN=$(cat ~/.config/op/connect-token)
elif [ -f ~/.config/op/service-account-token ]; then
    export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)
fi

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# Persist history across container rebuilds and share it live across all open
# terminals. ~/.local/share/igou-devenv is a bind mount (see devcontainer.json),
# so HISTFILE survives `make rebuild`. `history -a; history -n` flushes each
# command and pulls in commands typed in other terminals after every prompt.
if mkdir -p "$HOME/.local/share/igou-devenv/bash" 2>/dev/null; then
    HISTFILE="$HOME/.local/share/igou-devenv/bash/history"
fi
HISTSIZE=100000
HISTFILESIZE=200000
PROMPT_COMMAND="history -a; history -n${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        # We have color support; assume it's compliant with Ecma-48
        # (ISO/IEC-6429). (Lack of such support is extremely rare, and such
        # a case would tend to support setf rather than setaf.)
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
# --- igou-io devenv config ---

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

# Environment switching via 1Password (see adr/0001)
# Resolves op:// secrets via "op inject" and exports them in the current shell.
# Use unuse() to remove an environment's variables.
_use_sanitize() { echo "${1//-/_}"; }

# Kubeconfig-resolution failure path for use(). Called from inside use(), so it
# sees use()'s locals ($tmpkube, $keys) via dynamic scoping: report the error,
# remove the temp file, and roll back the keys already exported so a failed
# use() doesn't leave a half-active environment.
_use_kube_fail() {
    echo "Failed to resolve kubeconfig for ${1}"
    rm -f "$tmpkube"
    local k
    for k in "${keys[@]}"; do unset "$k"; done
}

# Registry-resolution failure path for use() — same dynamic-scoping contract
# as _use_kube_fail: report the error and roll back the keys already exported
# so a failed use() doesn't leave a half-active environment.
_use_registry_fail() {
    echo "Failed to resolve registry credentials for ${1}"
    local k
    for k in "${keys[@]}"; do unset "$k"; done
}

# Clean up temp kubeconfig files and registry-auth dirs on shell exit — but
# only those this shell created. The trap is registered in every interactive
# shell and _USE_TMP* vars are exported, so a short-lived child interactive
# shell would otherwise delete a parent/sibling shell's still-in-use temp
# files (issue #98). Each entry records its creator's $BASHPID in
# _USE_TMP{KUBE,AUTH}_OWNER_<name>; only the creating shell deletes.
_use_cleanup_all() {
    local varname name owner_var
    while IFS='=' read -r varname _; do
        case "$varname" in
            _USE_TMPKUBE_OWNER_*|_USE_TMPAUTH_OWNER_*) continue ;;
            _USE_TMPKUBE_*)
                name="${varname#_USE_TMPKUBE_}"
                owner_var="_USE_TMPKUBE_OWNER_${name}"
                [ "${!owner_var:-}" = "$BASHPID" ] && rm -f "${!varname}"
                ;;
            _USE_TMPAUTH_*)
                name="${varname#_USE_TMPAUTH_}"
                owner_var="_USE_TMPAUTH_OWNER_${name}"
                [ "${!owner_var:-}" = "$BASHPID" ] && rm -rf "${!varname}"
                ;;
        esac
    done < <(env)
}
trap _use_cleanup_all EXIT

# Resolve a single env-file value: op:// references via op read, plain values
# pass through unchanged.
_use_resolve_value() {
    case "$1" in
        op://*) op read "$1" ;;
        *)      printf '%s\n' "$1" ;;
    esac
}

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
    kubeconfig_data_ref=$(grep -m1 '^KUBECONFIG_DATA=' "$envfile" | cut -d= -f2-)
    kubeconfig_token_ref=$(grep -m1 '^KUBECONFIG_TOKEN=' "$envfile" | cut -d= -f2-)
    kubeconfig_host_ref=$(grep -m1 '^KUBECONFIG_HOST=' "$envfile" | cut -d= -f2-)

    if [ -n "$kubeconfig_data_ref" ] && { [ -n "$kubeconfig_token_ref" ] || [ -n "$kubeconfig_host_ref" ]; }; then
        echo "Error: ${1}.env has both KUBECONFIG_DATA and KUBECONFIG_TOKEN/KUBECONFIG_HOST — use one or the other"
        return 1
    fi
    if { [ -n "$kubeconfig_token_ref" ] && [ -z "$kubeconfig_host_ref" ]; } || \
       { [ -z "$kubeconfig_token_ref" ] && [ -n "$kubeconfig_host_ref" ]; }; then
        echo "Error: ${1}.env must have both KUBECONFIG_TOKEN and KUBECONFIG_HOST (found only one)"
        return 1
    fi

    # Parse container-registry strategy from env file. All three keys build a
    # temp containers-auth.json that podman/buildah/skopeo (REGISTRY_AUTH_FILE)
    # and docker (DOCKER_CONFIG) read:
    #   REGISTRY_HOST     — registry hostname (plain value or op:// ref)
    #   REGISTRY_USERNAME + REGISTRY_PASSWORD — credentials (op:// refs)
    # A subset is an error.
    local registry_host_ref registry_user_ref registry_pass_ref
    registry_host_ref=$(grep -m1 '^REGISTRY_HOST=' "$envfile" | cut -d= -f2-)
    registry_user_ref=$(grep -m1 '^REGISTRY_USERNAME=' "$envfile" | cut -d= -f2-)
    registry_pass_ref=$(grep -m1 '^REGISTRY_PASSWORD=' "$envfile" | cut -d= -f2-)

    if [ -n "${registry_host_ref}${registry_user_ref}${registry_pass_ref}" ] && \
       { [ -z "$registry_host_ref" ] || [ -z "$registry_user_ref" ] || [ -z "$registry_pass_ref" ]; }; then
        echo "Error: ${1}.env must have all of REGISTRY_HOST, REGISTRY_USERNAME, REGISTRY_PASSWORD (found a subset)"
        return 1
    fi

    # Resolve op:// references via op inject (one-shot, no wrapper process).
    # Kubeconfig- and registry-related keys are handled separately — strip them
    # before op inject.
    local remaining
    remaining=$(grep -v '^KUBECONFIG_DATA=\|^KUBECONFIG_TOKEN=\|^KUBECONFIG_HOST=\|^REGISTRY_HOST=\|^REGISTRY_USERNAME=\|^REGISTRY_PASSWORD=' "$envfile")

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
        # Clean up previous temp kubeconfig for this env if re-using — but only
        # if this shell created it. An inherited _USE_TMPKUBE_* var points at a
        # file a parent/sibling shell still uses (issue #98).
        local tmpvar="_USE_TMPKUBE_${safe_name}"
        local ownervar="_USE_TMPKUBE_OWNER_${safe_name}"
        if [ -n "${!tmpvar:-}" ] && [ "${!ownervar:-}" = "$BASHPID" ]; then
            rm -f "${!tmpvar}"
        fi
        local tmpkube
        tmpkube=$(mktemp /tmp/kubeconfig.XXXXXX)

        if [ -n "$kubeconfig_data_ref" ]; then
            # Full kubeconfig from 1Password (base64-encoded)
            local kube_b64
            if ! kube_b64=$(op read "$kubeconfig_data_ref") || \
               ! echo "$kube_b64" | base64 -d > "$tmpkube"; then
                _use_kube_fail "$1"
                return 1
            fi
        else
            # Build kubeconfig from token + host
            local kube_token kube_host
            if ! kube_token=$(echo "$kubeconfig_token_ref" | op inject) || [ -z "$kube_token" ]; then
                _use_kube_fail "$1"
                return 1
            fi
            if ! kube_host=$(echo "$kubeconfig_host_ref" | op inject) || [ -z "$kube_host" ]; then
                _use_kube_fail "$1"
                return 1
            fi
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
        # Record the creating shell so only it deletes the file on EXIT (issue #98)
        export "_USE_TMPKUBE_OWNER_${safe_name}=$BASHPID"
    fi

    if [ -n "$registry_host_ref" ]; then
        local registry_host registry_user registry_pass
        if ! registry_host=$(_use_resolve_value "$registry_host_ref") || [ -z "$registry_host" ]; then
            _use_registry_fail "$1"
            return 1
        fi
        if ! registry_user=$(_use_resolve_value "$registry_user_ref") || [ -z "$registry_user" ]; then
            _use_registry_fail "$1"
            return 1
        fi
        if ! registry_pass=$(_use_resolve_value "$registry_pass_ref") || [ -z "$registry_pass" ]; then
            _use_registry_fail "$1"
            return 1
        fi

        # Clean up previous temp auth dir for this env if re-using — but only
        # if this shell created it. An inherited _USE_TMPAUTH_* var points at a
        # dir a parent/sibling shell still uses (issue #98).
        local authvar="_USE_TMPAUTH_${safe_name}"
        local auth_ownervar="_USE_TMPAUTH_OWNER_${safe_name}"
        if [ -n "${!authvar:-}" ] && [ "${!auth_ownervar:-}" = "$BASHPID" ]; then
            rm -rf "${!authvar}"
        fi
        local tmpauth
        tmpauth=$(mktemp -d /tmp/registry-auth.XXXXXX)

        # containers-auth.json(5) shares docker's config.json "auths" schema,
        # so one file serves podman/buildah/skopeo (REGISTRY_AUTH_FILE points
        # at the file) and docker (DOCKER_CONFIG points at the directory).
        local auth_b64
        auth_b64=$(printf '%s:%s' "$registry_user" "$registry_pass" | base64 -w0)
        cat > "${tmpauth}/config.json" << AUTHJSON
{
  "auths": {
    "${registry_host}": {
      "auth": "${auth_b64}"
    }
  }
}
AUTHJSON
        chmod 600 "${tmpauth}/config.json"

        export REGISTRY_AUTH_FILE="${tmpauth}/config.json"
        export DOCKER_CONFIG="$tmpauth"
        keys+=("REGISTRY_AUTH_FILE" "DOCKER_CONFIG")
        export "$authvar=$tmpauth"
        # Record the creating shell so only it deletes the dir on EXIT (issue #98)
        export "_USE_TMPAUTH_OWNER_${safe_name}=$BASHPID"
        echo "Registry auth for '${registry_host}' written (podman/docker)"
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

    # Clean up temp kubeconfig — delete the file only if this shell created it.
    # An inherited _USE_TMPKUBE_* var points at a file a parent/sibling shell
    # still uses (issue #98); still unset this shell's copies of the vars.
    local tmpvar="_USE_TMPKUBE_${safe_name}"
    local ownervar="_USE_TMPKUBE_OWNER_${safe_name}"
    if [ -n "${!tmpvar:-}" ]; then
        [ "${!ownervar:-}" = "$BASHPID" ] && rm -f "${!tmpvar}"
        unset "$tmpvar"
    fi
    unset "$ownervar"

    # Clean up temp registry auth dir — delete it only if this shell created
    # it (issue #98, same rule as the kubeconfig above); still unset this
    # shell's copies of the vars.
    local authvar="_USE_TMPAUTH_${safe_name}"
    local auth_ownervar="_USE_TMPAUTH_OWNER_${safe_name}"
    if [ -n "${!authvar:-}" ]; then
        [ "${!auth_ownervar:-}" = "$BASHPID" ] && rm -rf "${!authvar}"
        unset "$authvar"
    fi
    unset "$auth_ownervar"

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

# SSH keys from 1Password (see adr/0004)
# A container-local ssh-agent listens on $SSH_AUTH_SOCK (started empty by
# post-start.sh via bin/ensure-ssh-agent — no host agent forwarding).
# ssh-use pipes a private key from 1Password straight into agent memory —
# never onto disk — with a bounded lifetime. ssh-unuse removes one key by its
# public half, or all keys with no argument.
#   ssh-use                  # load the default key (github)
#   ssh-use lab-nodes        # load op://lab_ssh/lab-nodes
#   SSH_USE_TTL=1h ssh-use   # override the default 12h lifetime
#   SSH_USE_VAULT=other ssh-use mykey
ssh-use() {
    local item="${1:-ansible}"
    local vault="${SSH_USE_VAULT:-lab_ssh}"
    local ttl="${SSH_USE_TTL:-12h}"
    if ! op read "op://${vault}/${item}/private key?ssh-format=openssh" \
            | ssh-add -t "$ttl" - 2>/dev/null; then
        echo "Failed to load SSH key '${item}' from vault '${vault}'"
        return 1
    fi
    echo "SSH key '${item}' loaded (expires in ${ttl})"
}

ssh-unuse() {
    if [ -z "${1:-}" ]; then
        if ! ssh-add -D 2>/dev/null; then
            echo "Failed to clear agent (no agent on ${SSH_AUTH_SOCK:-unset}?)"
            return 1
        fi
        echo "All SSH keys removed from agent"
        return 0
    fi
    local vault="${SSH_USE_VAULT:-lab_ssh}"
    if ! op read "op://${vault}/${1}/public key" | ssh-add -d - 2>/dev/null; then
        echo "Failed to remove SSH key '${1}' (not loaded, or vault '${vault}' unreachable)"
        return 1
    fi
    echo "SSH key '${1}' removed from agent"
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

# GitHub App tokens (ghapp) — the default path for GitHub auth, replacing the
# static-PAT `use claude-*-github-token` flow. Three ways to authenticate:
#   1. Plain `git` over HTTPS just works — the ghapp credential helper (baked into
#      /etc/gitconfig) mints a contents:write token for exactly the pushed repo.
#   2. `gh-app --repo OWNER/REPO -- <args>`  runs `gh` with a repo-scoped token in
#      GH_TOKEN, nothing exported into your shell.
#   3. `ght OWNER/REPO [perm=level ...]`  exports a fresh repo-scoped GH_TOKEN into
#      the CURRENT shell (for tools that read GH_TOKEN and can't use gh-app).
# App tokens are per-repository by design, so there is no org-wide GH_TOKEN — pass
# the repo. `ght-unset` clears it. Both orgs (david-igou, igou-io) resolve from the
# single App config; the owner half of OWNER/REPO selects the installation.
ght() {
    if [ -z "${1:-}" ]; then
        echo "usage: ght OWNER/REPO [perm=level ...]" >&2
        echo "  e.g. ght igou-io/igou-devenv            (default permissions)" >&2
        echo "       ght david-igou/hermes contents=read" >&2
        return 2
    fi
    local repo="$1"; shift
    local perm_args=() p
    for p in "$@"; do perm_args+=(--permission "$p"); done
    local tok
    tok=$(ghapp token --repo "$repo" "${perm_args[@]}") || {
        echo "ght: failed to mint a token for $repo" >&2
        return 1
    }
    export GH_TOKEN="$tok" GITHUB_TOKEN="$tok" GHT_REPO="$repo"
    echo "GH_TOKEN minted for $repo (repo-scoped, expires <1h)"
}
ght-unset() {
    unset GH_TOKEN GITHUB_TOKEN GHT_REPO
    echo "GH_TOKEN cleared"
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

# Auto-attach interactive code-server terminals to a persistent tmux session so
# they survive code-server restarts and browser reconnects. Open more terminals
# as tmux windows (Ctrl-b c) rather than new editor tabs — extra tabs attach to
# the same session and mirror it. tmux-resurrect/continuum (~/.tmux.conf) restore
# the layout across `make rebuild`. Scoped to TERM_PROGRAM=vscode so `make shell`,
# CI, and automation are unaffected; set NO_AUTO_TMUX=1 to opt out.
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ] && [ -z "${NO_AUTO_TMUX:-}" ] \
   && [ "${TERM_PROGRAM:-}" = "vscode" ] && command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s main
fi
