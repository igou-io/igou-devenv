# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a reproducible development environment for homelab infrastructure work. It contains only the container spec — the actual project code (Kubernetes, Ansible, Terraform, etc.) lives in separate repos cloned into `/workspace/` at container creation time.

## Architecture

```
.devcontainer/
├── Dockerfile           # apt packages (podman, buildah, skopeo, jq, direnv, etc.)
├── devcontainer.json    # devcontainer config; Features for kubectl, helm, terraform, go, python, node, gh, claude-code
├── post-create.sh       # Installs CLIs (ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl), clones repos, configures shell
└── requirements.txt     # Pinned Python packages (Ansible ecosystem, yq, mkdocs-material)
Makefile                 # Devcontainer lifecycle: build, up, down, shell, test, renovate targets
renovate.json            # Renovate config with custom regex manager for shell script version pins
test.sh                  # Dockerfile-only build test verifying apt-installed tools
.github/workflows/build.yaml  # CI: builds full devcontainer on push/PR via devcontainers/ci
```

**Tool installation layers:**

| Layer | What | Where to add |
|---|---|---|
| Dockerfile | apt packages (podman, buildah, skopeo, jq, etc.) | `.devcontainer/Dockerfile` |
| Devcontainer Features | kubectl, helm, terraform, tflint, go, python, node, gh, docker CLI, claude-code | `devcontainer.json` `features` block |
| pip (post-create) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |
| Binary downloads (post-create) | ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl | `.devcontainer/post-create.sh` |
| apt repo (post-create) | 1Password CLI | `.devcontainer/post-create.sh` |

**CLI binary versions** in `post-create.sh` use Renovate-compatible annotations:
```bash
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARGOCD_VERSION="v3.3.0"
```

## Common Commands

```bash
make build              # Build the devcontainer image (cached)
make up                 # Build and start the devcontainer
make rebuild            # Full rebuild from scratch (no cache)
make down               # Stop and remove the container
make shell              # Open bash shell in running container
make exec CMD="..."     # Run a one-off command in the container
make test               # Build Dockerfile and verify apt-installed tools
make renovate-validate  # Validate renovate.json config
GITHUB_TOKEN=... make renovate-dry-run  # Dry-run Renovate locally
```

## Linting

```bash
shellcheck .devcontainer/post-create.sh
```

## Key Design Decisions

- **SSH agent forwarding**: `devcontainer.json` sets `containerEnv.SSH_AUTH_SOCK` to `/tmp/ssh-agent.sock`. The Makefile dynamically mounts the host socket only if it exists (`[ -S "$SSH_AUTH_SOCK" ]`), avoiding errors from stale sockets.
- **Podman-in-container**: Runs `--privileged` with `fuse-overlayfs` and `slirp4netns` for nested container support.
- **pip over pipx**: Python packages installed directly via pip since isolation is unnecessary in a disposable container.
- **`~/.ssh` is read-only**: GitHub known_hosts must be written to `/etc/ssh/ssh_known_hosts` via `sudo tee`.
- **`podman-docker` required on host**: Cursor's devcontainer extension calls `docker` under the hood.
