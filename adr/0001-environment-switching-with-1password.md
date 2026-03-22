# ADR-0001: Environment Switching with 1Password CLI

## Status

Accepted

## Date

2026-03-21

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

Use 1Password CLI (`op run`) with per-environment `.env` files containing secret references (`op://` URIs). A shell function `use <env>` spawns a subshell with secrets injected for the duration of the session.

### Architecture

```
~/.config/envs/              # Host-side, mounted into container
├── k3s.env                  # op:// references for k3s cluster
├── openshift.env            # op:// references for OpenShift cluster
├── aap-homelab.env          # op:// references for AAP controller
└── k8s-serviceaccount.env   # op:// references for SA testing
```

### Secret reference format

`.env` files contain only `op://` references, never plaintext secrets:

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
use() {
    local envfile="$HOME/.config/envs/${1}.env"
    if [ ! -f "$envfile" ]; then
        echo "No env file: $envfile"
        echo "Available:"
        ls ~/.config/envs/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//'
        return 1
    fi
    # If env references a kubeconfig, write it to a temp file
    local kubeconfig_ref
    kubeconfig_ref=$(grep '^KUBECONFIG_DATA=' "$envfile" | cut -d= -f2)
    if [ -n "$kubeconfig_ref" ]; then
        local tmpkube
        tmpkube=$(mktemp /tmp/kubeconfig.XXXXXX)
        op read "$kubeconfig_ref" > "$tmpkube"
        KUBECONFIG="$tmpkube" op run --env-file="$envfile" -- bash
        rm -f "$tmpkube"
    else
        op run --env-file="$envfile" -- bash
    fi
}

k8s-unset() {
    unset KUBECONFIG KUBECONFIG_DATA K8S_AUTH_HOST K8S_AUTH_API_KEY K8S_AUTH_VERIFY_SSL
    echo "Kubernetes vars unset"
}
```

### Usage

```bash
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

# Stack environments
use k3s                 # k8s context
use aap-homelab         # now has k8s + aap vars

# Clear k8s context mid-session for SA testing
k8s-unset
```

### 1Password vault organization

Secrets are stored in 1Password with a consistent naming convention:

```
Vault: Homelab
├── k3s/kubeconfig              # kubeconfig file content
├── k3s-aws/access-key          # AWS access key ID
├── k3s-aws/secret-key          # AWS secret access key
├── openshift/kubeconfig
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

- **Secrets never on disk**: `op run` injects them only for the subprocess lifetime; kubeconfig temp files are cleaned up on exit
- **Subshell isolation**: `exit` cleanly removes all secrets from the environment
- **Composable**: nest `use` calls to combine environments (k8s + aap)
- **`.env` files are safe to commit**: they contain only `op://` references, not secrets
- **Easy to audit**: `env | grep -E 'AWS|KUBE|CONTROLLER'` shows what's active
- **Consistent pattern**: same mechanism for Kubernetes, AWS, AAP, Ansible vaults, and service accounts

### Tradeoffs

- Requires 1Password service account with access to all referenced vaults
- Each `use` invocation spawns a subshell — nested environments add shell depth
- Kubeconfig-as-file requires `op read` + temp file since `kubectl` expects a file path, not env var content
- Service account token must be present on the host at `~/.config/op/service-account-token`

### Security considerations

- `.env` files contain no secrets and can live in version control or on the host filesystem
- Temp kubeconfig files are created with `mktemp` (mode 600) and deleted on subshell exit
- `OP_SERVICE_ACCOUNT_TOKEN` is the single credential to protect — it is mounted read-only from the host
