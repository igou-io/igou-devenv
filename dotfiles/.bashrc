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

# Environment switching via 1Password (see adr/0001)
# Resolves op:// secrets via "op inject" and exports them in the current shell.
# Use unuse() to remove an environment's variables.
_use_sanitize() { echo "${1//-/_}"; }

# Clean up temp kubeconfig files on shell exit — but only for files this shell
# created. The trap is registered in every interactive shell and _USE_TMPKUBE_*
# vars are exported, so a short-lived child interactive shell would otherwise
# delete a parent/sibling shell's still-in-use kubeconfig (issue #98). Each entry
# records its creator's $BASHPID in _USE_TMPKUBE_OWNER_<name>; only the creating
# shell deletes the file.
_use_cleanup_all() {
    local varname name owner_var
    while IFS='=' read -r varname _; do
        [[ "$varname" == _USE_TMPKUBE_* ]] || continue
        [[ "$varname" == _USE_TMPKUBE_OWNER_* ]] && continue
        name="${varname#_USE_TMPKUBE_}"
        owner_var="_USE_TMPKUBE_OWNER_${name}"
        [ "${!owner_var:-}" = "$BASHPID" ] && rm -f "${!varname}"
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
        # Record the creating shell so only it deletes the file on EXIT (issue #98)
        export "_USE_TMPKUBE_OWNER_${safe_name}=$BASHPID"
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
    unset "_USE_TMPKUBE_OWNER_${safe_name}"

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
