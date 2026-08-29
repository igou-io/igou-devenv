# shellcheck shell=bash
# Sourced by ~/.bashrc for EVERY shell (interactive and not), so agent tool calls
# and scripts get these functions too. Keep it free of prompt/tty assumptions.

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
