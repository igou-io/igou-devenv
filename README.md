# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Runs as a devcontainer via Cursor or the `devcontainer` CLI, with SSH agent
forwarding for private repos.

## What's Inside

**Kubernetes:** kubectl, helm, kustomize, ArgoCD CLI, kubeseal, flux, virtctl,
kubeconform, kube-burner, kube-burner-ocp, tkn (Tekton)

**Infrastructure:** Terraform, SOPS, age, rclone

**Ansible:** ansible, ansible-navigator, ansible-builder,
ansible-runner, ansible-lint

**OpenShift:** oc CLI, crc (OpenShift Local)

**Container Tooling:** podman, buildah, skopeo (native in container, runs
privileged for nested container support), Docker CLI (via host socket)

**Cloud & Storage:** AWS CLI (via env switching), MinIO client (mc)

**CI/CD:** GitHub CLI, act (local GitHub Actions)

**General:** 1Password CLI, jq, yq, direnv, shellcheck, yamllint, make,
tree, nmap, tmux, vim, htop

**AI:** Claude Code (`claude` CLI — native binary)

### How Tools Are Installed

| Layer | What | Where to add |
|---|---|---|
| Dockerfile (apt) | podman, buildah, skopeo, jq, direnv, 1Password CLI, etc. | `.devcontainer/Dockerfile` |
| Dockerfile (binary downloads) | ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl, act, crc, kube-burner, tkn, mc, rclone, claude-code | `.devcontainer/Dockerfile` (ARG + RUN) |
| Devcontainer Features | kubectl, helm, terraform, python, node, gh, docker CLI | `devcontainer.json` `features` block |
| pip (onCreateCommand) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |

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
   - `~/.gitconfig` — Git identity (mounted read-only)
   - `~/.config/argocd/` — ArgoCD CLI config
   - `~/.config/op/service-account-token` — 1Password service account token
   - `~/.terraform.d/` — Terraform plugin cache/credentials
   - `~/.claude/` and `~/.claude.json` — Claude Code config

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
- Adds GitHub to known_hosts
- Clones all igou-io repos (public and private) into `/workspace/`
- Configures `.bashrc` with prompt, environment switching, aliases, and direnv
- Symlinks `bin/` into `~/bin` (on PATH) for custom scripts
- Creates a `homelab.code-workspace` file

Your repos will be at:
```
/workspace/
├── igou-ansible/
├── igou-containers/
├── igou-devenv/           (this repo)
│   ├── bin/               (symlinked to ~/bin, on PATH)
│   └── envs/              (1Password env files for use())
├── igou-infrastructure/
├── igou-inventory/          (private)
├── igou-kubernetes/
├── igou-kubernetes-private/ (private)
├── igou-openshift/
└── homelab.code-workspace
```

Open the workspace via **File > Open Workspace from File** → `/workspace/homelab.code-workspace`

## Environment Switching

The `use` shell function switches between infrastructure environments using
1Password for secret resolution. See [ADR-0001](adr/0001-environment-switching-with-1password.md)
for full details.

```bash
use                     # list available environments
use ocp-hub             # activate OpenShift hub (spawns subshell with secrets)
use ansible             # stack Ansible vault on top
exit                    # back to ocp-hub
exit                    # back to clean shell

k8s-unset               # clear KUBECONFIG and K8S_AUTH_* vars
```

Environment files live in `envs/` and contain only `op://` references — no
secrets are stored in the repo.

## Makefile Targets

| Target | Description |
|---|---|
| `make build` | Build the devcontainer image (cached) |
| `make up` | Build and start the devcontainer |
| `make rebuild` | Full rebuild from scratch (no cache) |
| `make down` | Stop and remove the container |
| `make shell` | Open a bash shell in the running container |
| `make exec CMD="..."` | Run a one-off command in the container |
| `make test` | Run all tests (tools, podman, env) |
| `make test-tools` | Verify CLI tools, Python packages, and user config |
| `make test-podman` | Test podman pull, run, and build |
| `make test-env` | Test environment switching functions |
| `make clean` | Down + prune dangling images |
| `make renovate-validate` | Validate `renovate.json` config |
| `make renovate-dry-run` | Dry-run Renovate locally (requires `GITHUB_TOKEN`) |
| `make claude-build` | Build the Claude container image (UBI10) |
| `make claude-rebuild` | Rebuild Claude container from scratch |
| `make claude-test` | Run tool verification in the Claude container |
| `make claude-test-hardened` | Test under full hardening (cap-drop=ALL, noexec, limits) |
| `make claude-test-run` | Test claude-run secret resolution and argument assembly |
| `make claude-test-all` | Run all Claude container tests (tools, hardened, claude-run) |
| `make e2e` | Full end-to-end: rebuild devcontainer, run all tests, build + test Claude container |

## Claude Container

A separate UBI10-based container for running Claude Code sessions against
infrastructure repos. Runs rootless via podman from inside the devcontainer,
with selective credential injection per session.

### Build

```bash
make claude-build       # build the image
make claude-test        # verify all tools
make claude-test-all    # run all tests (tools, hardened, claude-run)
```

### Usage

The `claude-run` script (in `bin/`, on PATH) launches the container:

```bash
claude-run                          # launch claude with current directory mounted
claude-run -e ocp-rosa              # resolve ocp-rosa secrets, inject as env vars
claude-run -e ocp-hub -e ansible    # stack multiple environments
claude-run --shell                  # drop to bash instead of claude
claude-run -e aws -- --resume       # pass flags through to claude
```

Credentials are resolved via `op inject` in the devcontainer before being
passed as plain environment variables to the Claude container. The container
never has direct access to 1Password.

### Differences from the devcontainer

| | Devcontainer | Claude Container |
|---|---|---|
| Base image | Ubuntu (devcontainers/base) | UBI10 (ubi-micro) |
| Container engine | podman, buildah, skopeo, Docker CLI | None (no nested containers) |
| Devcontainer Features | kubectl, helm, terraform, python, node, gh, docker | Installed via binary downloads |
| Privileged mode | Yes (for nested podman) | No (rootless via `--userns=keep-id`) |
| Hardening | None (general-purpose) | `--cap-drop=ALL`, noexec /tmp, bubblewrap + seccomp sandbox |
| Launched via | Cursor / `make up` | `claude-run` from inside devcontainer |

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

The shell prompt auto-heals stale SSH agent sockets on every prompt via
`_fix_ssh_auth_sock` in PROMPT_COMMAND.

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
- **CLI binaries** — pinned in `Dockerfile` with `# renovate:` comments, updated by a custom regex manager using the `github-releases` datasource
- **npm build-time deps** — pinned in `claude-container/package.json`, updated by Renovate's native npm manager

To test Renovate config locally:
```bash
make renovate-validate                     # validate config syntax
GITHUB_TOKEN=ghp_... make renovate-dry-run # see what would be updated
```

## CI

GitHub Actions builds the devcontainer on every push and PR to `main` using
[devcontainers/ci](https://github.com/devcontainers/ci). The workflow builds
the full image (Dockerfile + Features + lifecycle hooks) and runs the full
test suite (`tests/run-all.sh`) inside the container.

## Customization

### Adding Tools

- **apt packages** → add to `Dockerfile`
- **Devcontainer Features** → add to `devcontainer.json` `features` block
- **Python packages** → add to `.devcontainer/requirements.txt` (pinned for Renovate)
- **CLI binaries from GitHub** → add to `Dockerfile` with a `# renovate:` ARG comment
- **npm build-time deps** → add to `claude-container/package.json` (Renovate-managed)
- **Custom scripts** → add to `bin/` (symlinked to `~/bin`, on PATH)
- **Cursor extensions** → add to `customizations.vscode.extensions` in `devcontainer.json`

### 1Password Integration

The 1Password CLI authenticates via `OP_SERVICE_ACCOUNT_TOKEN`, sourced
automatically from `~/.config/op/service-account-token` (bind-mounted
read-only from the host).

Use the `use` function for environment switching — see
[ADR-0001](adr/0001-environment-switching-with-1password.md).

### Secrets Management

Credentials are bind-mounted from the host. SSH keys and `.gitconfig` are
read-only; kubeconfig is read-write for context switching. The container
never stores secrets in its image layers.

## Reprovisioning the Host

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fedora/RHEL
sudo dnf install -y podman podman-docker openssh-server
systemctl --user enable --now podman.socket
loginctl enable-linger $USER

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.config/op ~/.terraform.d ~/.claude
echo '{}' > ~/.claude.json
touch ~/.gitconfig

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

### Environment Switching

**`use` hangs:** Set `BASHRC_DEBUG=1` before the `use` call to trace shell
startup and identify which `.bashrc` section is blocking:
```bash
BASHRC_DEBUG=1 use ocp-hub
```
