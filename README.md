# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Runs as a devcontainer via Cursor or the `devcontainer` CLI, with SSH agent
forwarding for private repos.

## What's Inside

**Languages & Runtimes:** Go, Python 3.12, Node.js

**Kubernetes:** kubectl, helm, kustomize, ArgoCD CLI, kubeseal, flux, virtctl

**Infrastructure:** Terraform, tflint, SOPS, age

**Ansible:** ansible, ansible-navigator, ansible-builder,
ansible-rulebook, ansible-runner, ansible-lint, awxkit

**OpenShift:** oc CLI

**Container Tooling:** podman, buildah, skopeo (native in container, runs
privileged for nested container support), Docker CLI (via host socket)

**General:** 1Password CLI, GitHub CLI, jq, yq, direnv, shellcheck, make,
tree, p7zip, mkdocs-material

**AI:** Claude Code (`claude` CLI)

### How Tools Are Installed

| Layer | What | Where to add |
|---|---|---|
| Dockerfile | apt packages (podman, buildah, skopeo, jq, etc.) | `.devcontainer/Dockerfile` |
| Devcontainer Features | kubectl, helm, terraform, tflint, go, python, node, gh, docker CLI, claude-code | `.devcontainer/devcontainer.json` `features` block |
| pip (post-create) | Ansible ecosystem, yq, mkdocs-material, kubernetes, jmespath | `.devcontainer/requirements.txt` |
| Binary downloads (post-create) | ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl | `.devcontainer/post-create.sh` |
| apt repo (post-create) | 1Password CLI | `.devcontainer/post-create.sh` |

## Quick Start

### Prerequisites (on the host)

1. **Podman** installed and running rootless
2. **Podman socket** enabled:
   ```bash
   systemctl --user enable --now podman.socket
   ls $XDG_RUNTIME_DIR/podman/podman.sock
   ```
3. **Docker CLI symlink** — Cursor's devcontainer extension calls `docker`
   under the hood even when configured for podman:
   ```bash
   # Fedora/RHEL:
   sudo dnf install -y podman-docker
   # Ubuntu/Debian:
   sudo apt install -y podman-docker
   ```
4. **SSH agent running with your key loaded** — required for cloning private
   repos (igou-inventory, igou-kubernetes-private):
   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519   # or whichever key has GitHub access
   ssh -T git@github.com       # verify
   ```
5. **Cursor** with the **Dev Containers** extension, or **devcontainer CLI**:
   ```bash
   npm install -g @devcontainers/cli
   ```
6. **Cursor setting** to use podman — in Settings, set `dev.containers.dockerPath`
   to `podman`.
7. Your credentials in the standard locations:
   - `~/.ssh/` — SSH keys and config
   - `~/.kube/` — Kubernetes configs
   - `~/.config/argocd/` — ArgoCD CLI config (create if missing: `mkdir -p ~/.config/argocd`)
   - `~/.terraform.d/` — Terraform plugin cache/credentials

### Open via Cursor

```bash
git clone https://github.com/igou-io/igou-devenv.git ~/igou-devenv
cd ~/igou-devenv
cursor .
```

Then from the command palette (Ctrl+Shift+P): **Dev Containers: Reopen in Container**

### Open via CLI

```bash
make up      # build and start the devcontainer
make shell   # open a shell inside
make down    # stop and remove the container
```

The Makefile automatically forwards your SSH agent if `SSH_AUTH_SOCK` is set
and the socket exists.

### After First Build

The `post-create.sh` script automatically:
- Verifies SSH agent forwarding
- Installs Python packages from `requirements.txt`
- Installs 1Password CLI and pinned CLI tool versions
- Clones all igou-io repos (public and private) into `/workspace/`
- Configures bashrc with exports, aliases, and direnv
- Creates a `homelab.code-workspace` file

Your repos will be at:
```
/workspace/
├── igou-ansible/
├── igou-containers/
├── igou-infrastructure/
├── igou-inventory/          (private)
├── igou-kubernetes/
├── igou-kubernetes-private/ (private)
├── igou-openshift/
└── homelab.code-workspace
```

Open the workspace via **File > Open Workspace from File** → `/workspace/homelab.code-workspace`

## Makefile Targets

| Target | Description |
|---|---|
| `make build` | Build the devcontainer image (cached) |
| `make up` | Build and start the devcontainer |
| `make rebuild` | Full rebuild from scratch (no cache) |
| `make down` | Stop and remove the container |
| `make shell` | Open a bash shell in the running container |
| `make exec CMD="..."` | Run a one-off command in the container |
| `make test` | Build Dockerfile and verify apt-installed tools |
| `make clean` | Down + prune dangling images |
| `make renovate-validate` | Validate `renovate.json` config |
| `make renovate-dry-run` | Dry-run Renovate locally (requires `GITHUB_TOKEN`) |

## SSH Agent Forwarding

**Via Cursor:** The devcontainer bind-mounts `SSH_AUTH_SOCK` from the host into
the container at `/tmp/ssh-agent.sock`. Cursor handles this when you have
`ForwardAgent yes` in your SSH config.

**Via Makefile:** The `make up`/`make rebuild` commands detect your
`SSH_AUTH_SOCK` and pass it via `--mount` and `--remote-env`. If the socket
doesn't exist (stale agent, different terminal), it's silently skipped — the
container still starts but private repo cloning will warn.

**For the forwarding chain to work:**
1. Your local machine has `ssh-agent` running with your key
2. Your SSH config for the remote host has `ForwardAgent yes`
3. The host's `sshd_config` has `AllowAgentForwarding yes` (default on most distros)

## Container Tooling

The container runs in `--privileged` mode, enabling podman to run containers
natively inside:

```bash
podman build -t myimage .
podman run --rm myimage
buildah bud -t myimage .
```

Podman is configured with `fuse-overlayfs` for storage and `slirp4netns` for
rootless networking. Docker CLI is also available via the host socket
(docker-outside-of-docker Feature).

## Dependency Management (Renovate)

All tool versions are pinned and managed by [Renovate](https://docs.renovatebot.com/):

- **Dockerfile base image** — pinned by digest, updated by Renovate's Docker manager
- **Python packages** — pinned in `.devcontainer/requirements.txt`, updated by `pip_requirements` manager
- **CLI binaries** — pinned in `post-create.sh` with `# renovate:` comments, updated by a custom regex manager using the `github-releases` datasource

To test Renovate config locally:
```bash
make renovate-validate                     # validate config syntax
GITHUB_TOKEN=ghp_... make renovate-dry-run # see what would be updated
```

## CI

GitHub Actions builds the devcontainer on every push and PR to `main` using
[devcontainers/ci](https://github.com/devcontainers/ci). The workflow builds
the full image (Dockerfile + Features + post-create.sh) and runs tool
verification inside the container.

## Customization

### Adding Tools

- **apt packages** → add to `Dockerfile`
- **Devcontainer Features** → add to `devcontainer.json` `features` block
- **Python packages** → add to `.devcontainer/requirements.txt` (pinned for Renovate)
- **CLI binaries from GitHub** → add to `post-create.sh` with a `# renovate:` comment
- **Cursor extensions** → add to `customizations.vscode.extensions` in `devcontainer.json`

### 1Password Integration

The 1Password CLI is installed in the container. Authenticate with:
```bash
eval $(op signin)
```

For the Ansible vault password via 1Password:
```bash
export ANSIBLE_VAULT_PASSWORD_FILE=/workspace/igou-ansible/.vaultpassword.sh
```

### Secrets Management

Credentials are bind-mounted from the host. SSH keys are read-only; kubeconfig
is read-write for context switching. The container never stores secrets in its
image layers.

For SOPS/age, add your age key mount to `devcontainer.json`:
```jsonc
"source=${localEnv:HOME}/.config/sops/age,target=/home/vscode/.config/sops/age,type=bind,readonly"
```

## Reprovisioning the Host

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fedora/RHEL
sudo dnf install -y podman podman-docker openssh-server
systemctl --user enable --now podman.socket
loginctl enable-linger $USER

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.terraform.d

echo "Host ready. Clone devenv and open with: cursor ~/igou-devenv"
```

## Troubleshooting

### SSH Agent Forwarding

**Private repo clone fails with "Permission denied (publickey)":**
```bash
# Inside the container:
ssh-add -l
echo $SSH_AUTH_SOCK
ls -la /tmp/ssh-agent.sock
```
If the socket doesn't exist, the agent wasn't forwarded. Check that:
- Your local `ssh-agent` is running and has keys (`ssh-add -l` locally)
- Your SSH config for the host has `ForwardAgent yes`
- You started Cursor *after* starting the agent

**Stale SSH_AUTH_SOCK in another terminal:**
The Makefile validates the socket exists before mounting. If `SSH_AUTH_SOCK`
points to a dead socket, re-start your agent:
```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

### Podman

**Socket not found:**
```bash
systemctl --user status podman.socket
export XDG_RUNTIME_DIR=/run/user/$(id -u)
loginctl enable-linger $USER
```

### Cursor + Devcontainers

**"Reopen in Container" not appearing:** Open command palette (Ctrl+Shift+P) →
`Dev Containers: Reopen in Container`

**Extension calls `docker` despite `dockerPath` setting:** Install `podman-docker`.

**Extensions missing after connecting:** Command palette → **Dev Containers: Rebuild Container**.
