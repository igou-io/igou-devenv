# shellcheck shell=bash
# In-cluster scoped sessions (Hermes kubernetes terminal backend, adr/0006):
# the pod carries AGENT_PROFILE plus an env-file catalog rendered by an
# ExternalSecret at $AGENT_PROFILE_ENVDIR (same envs/*.env format, literal
# values, no 1Password). Activate it once per pod and cache the exports so
# every later shell (BASH_ENV) just sources the cache.
if [ -n "${AGENT_PROFILE:-}" ] && [ -z "${AGENT_PROFILE_ACTIVE:-}" ]; then
    _ap_envdir="${AGENT_PROFILE_ENVDIR:-/etc/agent/envs}"
    _ap_cache="${AGENT_PROFILE_CACHE:-/tmp/agent-profile.${AGENT_PROFILE//,/-}.env}"
    if [ -d "$_ap_envdir" ]; then
        if [ ! -s "$_ap_cache" ]; then
            _ap_resolver="$(command -v resolve-profile 2>/dev/null || echo /workspace/igou-devenv/bin/resolve-profile)"
            _ap_tmp="$(mktemp "${_ap_cache}.XXXXXX")"
            # shellcheck disable=SC2086
            if IGOU_ENVDIR="$_ap_envdir" "$_ap_resolver" ${AGENT_PROFILE//,/ } 2>/dev/null \
                    | sed 's/^/export /' > "$_ap_tmp" && [ -s "$_ap_tmp" ]; then
                chmod 600 "$_ap_tmp" && mv -f "$_ap_tmp" "$_ap_cache"
            else
                rm -f "$_ap_tmp"
            fi
        fi
        # shellcheck disable=SC1090
        [ -s "$_ap_cache" ] && . "$_ap_cache" && export AGENT_PROFILE_ACTIVE=1
    fi
    unset _ap_envdir _ap_cache _ap_resolver _ap_tmp
fi
