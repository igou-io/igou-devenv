# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a reproducible development environment for homelab infrastructure work. It contains only the container spec — the actual project code (Kubernetes, Ansible, Terraform, etc.) lives in separate repos cloned into `/workspace/` at container creation time.

## Architecture

```
.devcontainer/
├── Dockerfile           # apt packages, 1Password CLI, CLI binary downloads (ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl)
├── devcontainer.json    # devcontainer config; Features, lifecycle hooks, editor customizations, security settings
├── init.sh              # Host-side initializeCommand: creates mount directories if missing
├── post-create.sh       # Clones repos via SSH, configures shell, writes workspace file
├── post-start.sh        # SSH agent forwarding check (runs every container start)
└── requirements.txt     # Pinned Python packages (Ansible ecosystem, yq, mkdocs-material)
envs/                    # 1Password env files (op:// references only, no secrets) for use() function
Makefile                 # Devcontainer lifecycle: build, up, down, shell, test, renovate targets
renovate.json            # Renovate config with custom regex manager for Dockerfile ARGs and shell script version pins
test.sh                  # Dockerfile-only build test verifying apt and binary-installed tools
.github/workflows/build.yaml  # CI: builds full devcontainer on push/PR via devcontainers/ci
```

**Tool installation layers:**

| Layer | What | Where to add |
|---|---|---|
| Dockerfile (apt) | podman, buildah, skopeo, jq, direnv, 1Password CLI, etc. | `.devcontainer/Dockerfile` |
| Dockerfile (binary downloads) | ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl | `.devcontainer/Dockerfile` (ARG + RUN) |
| Devcontainer Features | kubectl, helm, terraform, python, node, gh, docker CLI, claude-code | `devcontainer.json` `features` block |
| pip (onCreateCommand) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |

**Lifecycle hooks** (execution order):

| Hook | Runs on | Script | Purpose |
|---|---|---|---|
| `initializeCommand` | Host | `init.sh` | Creates mount directories before container build |
| `onCreateCommand` | Container | (inline) | `pip install` — runs after Features install Python |
| `postCreateCommand` | Container | `post-create.sh` | Clones repos, shell config, workspace file |
| `postStartCommand` | Container | `post-start.sh` | SSH agent check (every start) |

**CLI binary versions** in `Dockerfile` use Renovate-compatible annotations:
```dockerfile
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION="v3.3.0"
```

## Common Commands

```bash
make build              # Build the devcontainer image (cached)
make up                 # Build and start the devcontainer
make rebuild            # Full rebuild from scratch (no cache)
make down               # Stop and remove the container
make shell              # Open bash shell in running container
make exec CMD="..."     # Run a one-off command in the container
make test               # Build Dockerfile and verify apt + binary tools
make renovate-validate  # Validate renovate.json config
GITHUB_TOKEN=... make renovate-dry-run  # Dry-run Renovate locally
```

## Linting

```bash
shellcheck .devcontainer/post-create.sh .devcontainer/post-start.sh .devcontainer/init.sh
```

## Key Design Decisions

- **Lifecycle hook separation**: Tool installs are cached in Docker layers (Dockerfile) or run once after Features (onCreateCommand). Workspace setup (repo cloning, shell config) runs in postCreateCommand. SSH agent checks run every start via postStartCommand.
- **SSH agent forwarding**: `devcontainer.json` sets `containerEnv.SSH_AUTH_SOCK` to `/tmp/ssh-agent.sock`. The Makefile dynamically mounts the host socket only if it exists (`[ -S "$SSH_AUTH_SOCK" ]`), avoiding errors from stale sockets.
- **Podman-in-container**: Uses `SYS_ADMIN`, `MKNOD`, `NET_ADMIN` capabilities with `/dev/fuse` device, `seccomp=unconfined`, and `apparmor=unconfined` for nested container support without full `--privileged`.
- **pip over pipx**: Python packages installed directly via pip since isolation is unnecessary in a disposable container.
- **`~/.ssh` is read-only**: GitHub known_hosts must be written to `/etc/ssh/ssh_known_hosts` via `sudo tee`.
- **`podman-docker` required on host**: Cursor's devcontainer extension calls `docker` under the hood.
- **CI compatibility**: `init.sh` creates mount directories on any host (including CI runners). Scripts check `$CI` to skip SSH-dependent operations.
