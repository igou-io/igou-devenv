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

# The VS Code Dev Containers extension injects its own forwarded agent socket
# (/tmp/vscode-ssh-auth-*.sock) into shells, overriding the container-local
# agent devcontainer.json exports (adr/0004). The forward goes stale on editor
# reconnect — it can still list keys but fails to sign, and the resulting auth
# failures trip sshd per-source penalties on targets. Pin back to the
# container-local socket. Before the interactive check: agent tool calls and
# scripts inherit the injected value too.
case "${SSH_AUTH_SOCK:-}" in
    /tmp/vscode-ssh-auth-*) export SSH_AUTH_SOCK=/tmp/ssh-agent.sock ;;
esac

export PATH=$PATH:/home/igou/.local/bin:/home/igou/bin

# GitHub App runtime tokens (ghapp). Point the CLI + git credential helper at the
# per-user config seeded by post-create.sh. Exported unconditionally (not just for
# interactive shells) so `git`'s ghapp credential helper finds the config when git
# is invoked from scripts. The App private key is never on disk here — it is read
# from 1Password at mint time (config's private_key_cmd), so tokens are repo-scoped
# and expire within the hour. See README "GitHub Authentication (ghapp)".
export GHAPP_CONFIG="$HOME/.config/ghapp/config.yaml"

# 1Password auth. Prefer Connect (self-hosted, no service-account API rate
# limit); fall back to the service-account token when Connect creds are absent.
# All files are bind-mounted read-only from the host's ~/.config/op.
# Exported before the interactive check: ghapp resolves the App private key
# from 1Password at mint time, so gh-app, ghapp and git's credential helper
# fail in non-interactive shells (agent tool calls, scripts) with "No accounts
# configured for use with 1Password CLI" if these are only set for interactive
# shells. Skipped in Cursor agent shells to keep the secret-strip above intact.
if [ -z "${CURSOR_AGENT:-}" ]; then
    if [ -f ~/.config/op/connect-host ] && [ -f ~/.config/op/connect-token ]; then
        export OP_CONNECT_HOST=$(cat ~/.config/op/connect-host)
        export OP_CONNECT_TOKEN=$(cat ~/.config/op/connect-token)
    elif [ -f ~/.config/op/service-account-token ]; then
        export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)
    fi
fi

# Shell functions (use/unuse, ssh-use/ssh-unuse, ght, ...) live in ~/.bashrc.d/
# and are sourced for every shell, before the interactive check, so agent tool
# calls (`bash -c`) and scripts can `use ocp-cluster-reader && oc get nodes`
# without spawning an interactive shell. Installed from dotfiles/.bashrc.d by
# post-create.sh.
if [ -d "$HOME/.bashrc.d" ]; then
    for _rc in "$HOME"/.bashrc.d/*.sh; do
        # shellcheck disable=SC1090
        [ -r "$_rc" ] && . "$_rc"
    done
    unset _rc
fi

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

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
