# shellcheck shell=bash
# Sourced by ~/.bashrc for EVERY shell (interactive and not), so agent tool calls
# and scripts get these functions too. Keep it free of prompt/tty assumptions.

# Environment switching via 1Password (see adr/0001)
# Resolves op:// secrets via "op inject" and exports them in the current shell.
# Use unuse() to remove an environment's variables.
_use_sanitize() { echo "${1//-/_}"; }

# Clean up temp kubeconfig files and registry-auth dirs on shell exit — but
# only those this shell created. The trap is registered in every interactive
# shell and _USE_TMP* vars are exported, so a short-lived child interactive
# shell would otherwise delete a parent/sibling shell's still-in-use temp
# files (issue #98). Each entry records its creator's $BASHPID in
# _USE_TMP{KUBE,AUTH}_OWNER_<name>; only the creating shell deletes.
_use_cleanup_all() {
    local varname name owner_var p prev
    while IFS='=' read -r varname _; do
        case "$varname" in
            _USE_TMPKUBE_OWNER_*|_USE_TMPAUTH_OWNER_*) continue ;;
            _USE_TMPKUBE_*)
                name="${varname#_USE_TMPKUBE_}"
                owner_var="_USE_TMPKUBE_OWNER_${name}"
                if [ "${!owner_var:-}" = "$BASHPID" ]; then
                    prev="${!varname}"
                    for p in ${prev//:/ }; do rm -f "$p"; done
                fi
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

# Record a temp path (kind KUBE or AUTH) created for env <name>: remove the
# previous one if THIS shell created it, then mark this shell as the owner so
# only it deletes the path on EXIT/unuse (issue #98).
_use_track_tmp() {
    local tmpvar="_USE_TMP${1}_${2}" ownervar="_USE_TMP${1}_OWNER_${2}" old prev
    if [ -n "${!tmpvar:-}" ] && [ "${!ownervar:-}" = "$BASHPID" ]; then
        prev="${!tmpvar}"
        for old in ${prev//:/ }; do rm -rf "$old"; done
    fi
    export "$tmpvar=$3" "$ownervar=$BASHPID"
}

# Resolution itself lives in bin/resolve-profile (shared with every container
# launcher); use() only exports the result and tracks it for unuse.
use() {
    local devenv="${IGOU_DEVENV:-/workspace/igou-devenv}"
    local resolver="${devenv}/bin/resolve-profile"
    local envdir="${IGOU_ENVDIR:-${devenv}/envs}"
    if [ -z "${1:-}" ]; then
        echo "Available environments:"
        IGOU_ENVDIR="$envdir" "$resolver" --list
        return 0
    fi
    local safe_name
    safe_name=$(_use_sanitize "$1")

    # Atomic: on any failure nothing is printed and no temp files remain, so a
    # failed use() never leaves a half-active environment.
    local resolved
    resolved=$(IGOU_ENVDIR="$envdir" "$resolver" "$1") || return 1

    local keys=() line key value
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            KUBECONFIG)    _use_track_tmp KUBE "$safe_name" "$value" ;;   # may be a:b list
            DOCKER_CONFIG) _use_track_tmp AUTH "$safe_name" "$value"
                           echo "Registry auth written to ${value}/config.json (podman/docker)" ;;
        esac
        export "$key=$value"
        keys+=("$key")
    done <<< "$resolved"

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
        if [ "${!ownervar:-}" = "$BASHPID" ]; then
            local p prev="${!tmpvar}"
            for p in ${prev//:/ }; do rm -f "$p"; done
        fi
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
