# shellcheck shell=bash
# Sourced by ~/.bashrc for EVERY shell (interactive and not), so agent tool calls
# and scripts get these functions too. Keep it free of prompt/tty assumptions.

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
