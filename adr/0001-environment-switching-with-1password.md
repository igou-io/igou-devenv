# ADR-0001: Environment Switching with 1Password CLI

## Status

Accepted

## Date

2026-03-21 (updated 2026-03-22)

## Context

The devcontainer serves as a general-purpose development environment for managing multiple infrastructure targets:

- **Kubernetes clusters**: k3s (ARM64 homelab), OpenShift (single-node x86), ROSA
- **AWS accounts**: different credentials per environment
- **AAP/AWX controllers**: multiple Controller endpoints with different auth
- **Ansible vaults**: per-environment vault passwords
- **Kubernetes service accounts**: for testing Ansible `K8S_AUTH_*` flows without a kubeconfig

Previously, credentials were managed by manually copy/pasting tokens and kubeconfigs into the shell, leading to:

- Secrets persisted in shell history
- No easy way to switch between environments
- Credentials left in environment after use
- Risk of operating against the wrong environment

## Decision

Use 1Password CLI (`op inject`) with per-environment `.env` files containing secret references (`op://` URIs). A shell function `use <env>` resolves secrets and spawns a subshell with them injected for the duration of the session.

### Architecture

```
envs/                        # Checked into the repo (no secrets, only op:// refs)
├── k3s.env                  # op:// references for k3s cluster
├── openshift.env            # op:// references for OpenShift cluster
├── aap-homelab.env          # op:// references for AAP controller
└── k8s-serviceaccount.env   # op:// references for SA testing
```

### Secret reference format

`.env` files contain only `op://` references, never plaintext secrets.

`KUBECONFIG_DATA` is a special key: its value is a base64-encoded kubeconfig stored in
1Password (since 1Password does not support multi-line secrets). The `use()` function
fetches it via `op read`, decodes it with `base64 -d`, and writes it to a temp file
that `KUBECONFIG` points to. The `KUBECONFIG_DATA` line is stripped before resolving
so the raw content is never exposed as an environment variable.

To store a kubeconfig in 1Password:
```bash
base64 -w0 < ~/.kube/config   # copy the output into the 1Password field
```

```bash
# Example: k3s.env
KUBECONFIG_DATA=op://Homelab/k3s/kubeconfig
AWS_ACCESS_KEY_ID=op://Homelab/k3s-aws/access-key
AWS_SECRET_ACCESS_KEY=op://Homelab/k3s-aws/secret-key
AWS_DEFAULT_REGION=us-east-1
```

```bash
# Example: aap-homelab.env
CONTROLLER_HOST=op://Homelab/aap-homelab/hostname
CONTROLLER_USERNAME=op://Homelab/aap-homelab/username
CONTROLLER_PASSWORD=op://Homelab/aap-homelab/password
CONTROLLER_VERIFY_SSL=false
```

```bash
# Example: k8s-serviceaccount.env
# No KUBECONFIG — forces Ansible to use K8S_AUTH_* vars
K8S_AUTH_HOST=op://Homelab/k3s-sa/host
K8S_AUTH_API_KEY=op://Homelab/k3s-sa/token
K8S_AUTH_VERIFY_SSL=false
```

### Shell function

```bash
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
    # Block if a kubeconfig env is already active
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
```

### Usage

```bash
# List available environments
use

# Activate an environment (spawns subshell with secrets)
use k3s
kubectl get nodes
exit                    # secrets removed, back to clean shell

# Activate AAP
use aap-homelab
awx job_templates list

# Test as service account (no kubeconfig, only K8S_AUTH_*)
use k8s-serviceaccount
ansible-playbook deploy.yml

# Stack environments (different envs only)
use k3s                 # k8s context
use aap-homelab         # now has k8s + aap vars

# Duplicate envs are rejected
use k3s                 # "Environment 'k3s' is already active"

# Two kubeconfig envs cannot be stacked
use k3s                 # sets KUBECONFIG
use openshift           # "A kubeconfig environment is already active (k3s)"

# Clear k8s context mid-session for SA testing
k8s-unset
```

### 1Password vault organization

Secrets are stored in 1Password with a consistent naming convention:

```
Vault: Homelab
├── k3s/kubeconfig              # base64-encoded kubeconfig
├── k3s-aws/access-key          # AWS access key ID
├── k3s-aws/secret-key          # AWS secret access key
├── openshift/kubeconfig         # base64-encoded kubeconfig
├── openshift-aws/access-key
├── openshift-aws/secret-key
├── aap-homelab/hostname        # https://controller.example.com
├── aap-homelab/username
├── aap-homelab/password
├── k3s-sa/host                 # API server URL
├── k3s-sa/token                # ServiceAccount token
├── ansible-vault/homelab       # Vault password
```

### Authentication

The `op` CLI authenticates via `OP_SERVICE_ACCOUNT_TOKEN`, which is stored at `~/.config/op/service-account-token` on the host and sourced into the container shell automatically (see devcontainer `.bashrc` config).

## Consequences

### Benefits

- **Secrets never on disk**: `op inject` resolves them at subshell start; kubeconfig temp files are cleaned up on exit
- **Subshell isolation**: `exit` cleanly removes all secrets from the environment
- **Composable**: nest `use` calls to combine environments (k8s + aap)
- **`.env` files are version-controlled**: they live in `envs/` in the repo — no host mount needed, and they contain only `op://` references, never secrets
- **Easy to audit**: `env | grep -E 'AWS|KUBE|CONTROLLER'` shows what's active
- **Consistent pattern**: same mechanism for Kubernetes, AWS, AAP, Ansible vaults, and service accounts

### Tradeoffs

- Requires 1Password service account with access to all referenced vaults
- Each `use` invocation spawns a subshell — nested environments add shell depth
- Kubeconfig-as-file requires `op read` + `base64 -d` + temp file since `kubectl` expects a file path and 1Password doesn't support multi-line secrets
- Service account token must be present on the host at `~/.config/op/service-account-token`
- Uses `op inject` + `env` instead of `op run` wrapper — resolved secrets are visible in the process environment (acceptable in a local devcontainer), but this avoids `op run` nesting deadlocks

### Security considerations

- `.env` files contain no secrets and are checked into the repo (`envs/` directory)
- Temp kubeconfig files are created with `mktemp` (mode 600) and deleted on subshell exit
- `OP_SERVICE_ACCOUNT_TOKEN` is the single credential to protect — it is mounted read-only from the host
