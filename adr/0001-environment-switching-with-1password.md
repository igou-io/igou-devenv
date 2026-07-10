# ADR-0001: Environment Switching with 1Password CLI

## Status

Accepted (updated 2026-07-10 — documented REGISTRY_* container-registry
authentication strategy)

## Date

2026-03-21 (updated 2026-03-22, 2026-03-30, 2026-04-15, 2026-07-10)

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

Use 1Password CLI (`op inject`) with per-environment `.env` files containing secret references (`op://` URIs). A shell function `use <env>` resolves secrets and exports them in the current shell. `unuse <env>` removes the exported variables and cleans up temp files.

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

There are two mutually exclusive strategies for injecting a kubeconfig. Both produce
a temp file that `KUBECONFIG` points to; the relevant keys are stripped before
`op inject` so the raw content is never exposed as an environment variable.

1. **`KUBECONFIG_DATA`** — a base64-encoded full kubeconfig stored in 1Password
   (since 1Password does not support multi-line secrets). The `use()` function fetches
   it via `op read`, decodes it with `base64 -d`, and writes it to a temp file.

   To store a kubeconfig in 1Password:
   ```bash
   base64 -w0 < ~/.kube/config   # copy the output into the 1Password field
   ```

2. **`KUBECONFIG_TOKEN` + `KUBECONFIG_HOST`** — dynamically constructs a minimal
   kubeconfig from a bearer token and API server URL. Useful for service account
   tokens where you don't have (or want) a full kubeconfig. The generated config
   uses `insecure-skip-tls-verify: true` and wires the token directly into the
   `users[].user.token` field.

Both keys present in the same `.env` file is an error. `KUBECONFIG_TOKEN` and
`KUBECONFIG_HOST` must both be present if either is used.

There is an analogous strategy for **container registry authentication**:

3. **`REGISTRY_HOST` + `REGISTRY_USERNAME` + `REGISTRY_PASSWORD`** — writes a
   temp `containers-auth.json` (the `auths` schema shared by docker's
   `config.json`) with a `base64(user:pass)` entry for the host, then exports
   `REGISTRY_AUTH_FILE` pointing at the file (read by podman, buildah, skopeo)
   and `DOCKER_CONFIG` pointing at its directory (read by docker). All three
   keys are required together; a subset is an error. `REGISTRY_HOST` may be a
   plain hostname or an `op://` reference; the credentials are `op://`
   references resolved via `op read`. `unuse` (or the shell exit trap,
   owner-scoped per issue #98) deletes the temp directory — no login state
   outlives the session, and nothing touches `~/.docker` or
   `${XDG_RUNTIME_DIR}/containers`.

```bash
# Example: quay.env
REGISTRY_HOST=quay.io
REGISTRY_USERNAME=op://lab_container_registries/quay/username
REGISTRY_PASSWORD=op://lab_container_registries/quay/password
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
# Uses KUBECONFIG_TOKEN/KUBECONFIG_HOST to build a kubeconfig from a service account token.
# This lets kubectl work without a pre-existing kubeconfig file.
KUBECONFIG_TOKEN=op://Homelab/k3s-sa/token
KUBECONFIG_HOST=op://Homelab/k3s-sa/host
```

```bash
# Example: k8s-auth-vars.env
# No KUBECONFIG — forces Ansible to use K8S_AUTH_* vars directly
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

See `dotfiles/.bashrc` for the full implementation.

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

The `op` CLI authenticates via **1Password Connect by default**
(`OP_CONNECT_HOST` + `OP_CONNECT_TOKEN`), falling back to
`OP_SERVICE_ACCOUNT_TOKEN` when the Connect credentials are absent. The
credentials are stored on the host under `~/.config/op/` and sourced into the
container shell automatically (see devcontainer `.bashrc` config). The
environment-switching mechanism is agnostic to how `op` authenticates. See
[ADR-0003](0003-default-to-1password-connect.md) for the Connect decision and
rationale.

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

- Requires 1Password Connect (or, as fallback, a service account) with access to all referenced vaults
- Kubeconfig-as-file requires either `op read` + `base64 -d` (full kubeconfig) or dynamic construction from token + host (service accounts), both written to a temp file since `kubectl` expects a file path and 1Password doesn't support multi-line secrets
- Dynamically constructed kubeconfigs use `insecure-skip-tls-verify: true` — appropriate for homelab but not for production clusters requiring CA verification
- 1Password Connect credentials (`~/.config/op/connect-host` + `~/.config/op/connect-token`) must be present on the host; the service-account token (`~/.config/op/service-account-token`) is the fallback (see [ADR-0003](0003-default-to-1password-connect.md))
- Resolved secrets are visible in the process environment (acceptable in a local devcontainer)
- If two environments set the same variable, the last `use` wins — `unuse` of either clears it (no save/restore)

### Security considerations

- `.env` files contain no secrets and are checked into the repo (`envs/` directory)
- Temp kubeconfig files are created with `mktemp` (mode 600) and deleted by `unuse` or shell exit trap
- The 1Password credential (`OP_CONNECT_TOKEN`, or `OP_SERVICE_ACCOUNT_TOKEN` as fallback) is the single credential to protect — it is mounted read-only from the host

### History

- **2026-03-22**: Initial implementation using `env VAR=val bash` subshells. Each `use` spawned a child shell; `exit` removed secrets. Worked but caused UX friction (shell depth, unintuitive `exit`, prompt resets).
- **2026-03-30**: Refactored to export variables in the current shell with `unuse` for cleanup (issue #11). Removed subshell spawning entirely.
- **2026-04-15**: Documented `KUBECONFIG_TOKEN` + `KUBECONFIG_HOST` strategy for dynamically constructing kubeconfigs from service account tokens.
- **2026-06-08**: Default `op` auth switched to 1Password Connect, with the service-account token kept as fallback (see [ADR-0003](0003-default-to-1password-connect.md)).
- **2026-07-10**: Added `REGISTRY_HOST` + `REGISTRY_USERNAME` + `REGISTRY_PASSWORD` strategy — `use quay` authenticates podman/buildah/skopeo (`REGISTRY_AUTH_FILE`) and docker (`DOCKER_CONFIG`) via a temp auth file cleaned up by `unuse` or the exit trap.
