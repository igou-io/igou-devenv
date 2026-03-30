# ADR-0001: Environment Switching with 1Password CLI

## Status

Accepted (updated 2026-03-30 — removed subshell spawning, added `unuse`)

## Date

2026-03-21 (updated 2026-03-22, 2026-03-30)

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

### Shell functions

`use()` resolves `op://` secrets via `op inject` and exports them directly in the current
shell. `unuse()` removes the exported variables and cleans up temp kubeconfig files.
Both are idempotent — `use` can be called repeatedly (re-resolves and re-exports),
`unuse` is a no-op if the environment isn't active.

Variable names are tracked per environment in `_USE_KEYS_<name>` so `unuse` knows what
to remove. `OP_ENV` shows the last-used environment (displayed in the prompt).
`OP_ENV_LIST` is a comma-separated list of all active environments used by `unuse`.

See `.devcontainer/post-create.sh` for the full implementation (embedded in the `.bashrc` heredoc).

### Usage

```bash
# List available environments
use

# Activate an environment (exports vars in current shell)
use k3s
kubectl get nodes

# Deactivate — removes exported vars, deletes temp kubeconfig
unuse k3s

# Activate AAP
use aap-homelab
awx job_templates list

# Stack environments
use k3s                 # k8s context
use aap-homelab         # adds aap vars, prompt shows "aap-homelab"

# Selective unuse
unuse aap-homelab       # removes aap vars, k3s vars remain

# Unuse all active environments
unuse

# Calling use twice is safe (idempotent, re-resolves secrets)
use k3s
use k3s                 # no error, re-exports

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

- **Secrets never on disk**: `op inject` resolves at activation; kubeconfig temp files are cleaned up by `unuse` or shell exit trap
- **Explicit cleanup with `unuse`**: removes environment variables and temp files without leaving the shell
- **Composable**: stack `use` calls to combine environments (k8s + aap); `unuse` selectively removes one
- **Idempotent**: `use` can be called repeatedly (re-resolves secrets); `unuse` is a no-op if not active
- **`.env` files are version-controlled**: they live in `envs/` in the repo — no host mount needed, and they contain only `op://` references, never secrets
- **Easy to audit**: `env | grep -E 'AWS|KUBE|CONTROLLER'` shows what's active
- **Consistent pattern**: same mechanism for Kubernetes, AWS, AAP, Ansible vaults, and service accounts

### Tradeoffs

- Requires 1Password service account with access to all referenced vaults
- Kubeconfig-as-file requires `op read` + `base64 -d` + temp file since `kubectl` expects a file path and 1Password doesn't support multi-line secrets
- Service account token must be present on the host at `~/.config/op/service-account-token`
- Resolved secrets are visible in the process environment (acceptable in a local devcontainer)
- If two environments set the same variable, the last `use` wins — `unuse` of either clears it (no save/restore)

### Security considerations

- `.env` files contain no secrets and are checked into the repo (`envs/` directory)
- Temp kubeconfig files are created with `mktemp` (mode 600) and deleted by `unuse` or shell exit trap
- `OP_SERVICE_ACCOUNT_TOKEN` is the single credential to protect — it is mounted read-only from the host

### History

- **2026-03-22**: Initial implementation using `env VAR=val bash` subshells. Each `use` spawned a child shell; `exit` removed secrets. Worked but caused UX friction (shell depth, unintuitive `exit`, prompt resets).
- **2026-03-30**: Refactored to export variables in the current shell with `unuse` for cleanup (issue #11). Removed subshell spawning entirely.
