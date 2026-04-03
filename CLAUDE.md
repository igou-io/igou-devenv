# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a reproducible development environment for homelab infrastructure work. It contains only the container spec — the actual project code (Kubernetes, Ansible, Terraform, etc.) lives in separate repos cloned into `/workspace/` at container creation time.

## Architecture

```
.devcontainer/
├── Dockerfile           # apt packages, 1Password CLI, CLI binary downloads, claude-code (native)
├── containers-storage.conf  # Podman rootless storage config (COPY'd into image)
├── devcontainer.json    # devcontainer config; Features, lifecycle hooks, editor customizations
├── init.sh              # Host-side initializeCommand: creates mount directories if missing
├── post-create.sh       # Clones repos via SSH, configures shell (.bashrc), writes workspace file
├── post-start.sh        # SSH agent forwarding check (runs every container start)
└── requirements.txt     # Pinned Python packages (Ansible ecosystem, yq, mkdocs-material)
containers/
├── base/
│   ├── Containerfile    # Shared UBI10 three-stage build (system packages, CLI tools, Python, hardening)
│   ├── requirements.txt # Pinned Python packages (single source of truth)
│   └── test.sh          # Base tool verification
├── claude-code/
│   ├── Containerfile    # Overlay: FROM agent-base + Claude Code CLI + seccomp
│   ├── package.json     # npm build-time deps (seccomp filter, Renovate-managed)
│   ├── claude.json      # Baked MCP server config (→ /etc/claude/)
│   ├── settings.json    # Baked sandbox settings (→ /etc/claude/)
│   ├── CLAUDE.md        # Global CLAUDE.md for container sessions
│   ├── merge-config.py  # JSON config merge script (→ /usr/local/lib/claude-container/)
│   ├── entrypoint.sh    # Git config, config merging, GitHub auth
│   ├── test.sh          # Claude-specific tool verification
│   ├── test-hardened.sh # Integration tests under full hardening (cap-drop, noexec, etc.)
│   └── test-claude-run.sh # Unit tests for claude-run launch script
└── cursor-agent-cli/
    ├── Containerfile    # Overlay: FROM agent-base + Cursor agent CLI
    ├── sandbox.json     # Baked Cursor sandbox config (→ /etc/cursor/, merged by entrypoint)
    ├── merge-sandbox.py # Sandbox config merge script (→ /usr/local/lib/cursor-container/)
    ├── entrypoint.sh    # Git config, sandbox merge, GitHub auth
    ├── test.sh          # Cursor-specific tool verification
    ├── test-hardened.sh # Integration tests under full hardening
    └── test-cursor-run.sh # Unit tests for cursor-run launch script
dotfiles/
├── bashrc               # Shell config appended to ~/.bashrc by post-create.sh
└── homelab.code-workspace  # VS Code workspace file copied to /workspace/
adr/                     # Architecture Decision Records
bin/                     # Custom scripts (symlinked to ~/bin, on PATH)
│   ├── claude-run       # Launch script for the Claude container
│   ├── cursor-run       # Launch script for the Cursor agent container
│   └── argocd-refresh-all
envs/                    # 1Password env files (op:// references only, no secrets) for use() function
Makefile                 # Devcontainer lifecycle: build, up, down, shell, test, renovate targets
tests/
├── run-all.sh           # Runs all test suites
├── test-tools.sh        # Verifies CLI tools, Python packages, user config
├── test-podman.sh       # Tests podman pull, run, and build
├── test-env.sh          # Tests environment switching functions (uses mock op)
└── mock-op.sh           # Mock 1Password CLI for test-env
renovate.json            # Renovate config with custom regex manager for Dockerfile ARGs
.github/workflows/build.yaml  # CI: builds full devcontainer on push/PR via devcontainers/ci
```

**Tool installation layers:**

| Layer | What | Where to add |
|---|---|---|
| Dockerfile (apt) | podman, buildah, skopeo, jq, direnv, 1Password CLI, etc. | `.devcontainer/Dockerfile` |
| Dockerfile (binary downloads) | ArgoCD, kustomize, kubeseal, flux, SOPS, oc, virtctl, act, crc, kube-burner, tkn, mc, rclone, claude-code | `.devcontainer/Dockerfile` (ARG + RUN) |
| Devcontainer Features | kubectl, helm, terraform, python, node, gh, docker CLI | `devcontainer.json` `features` block |
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

**Dependency version pinning preference**: When a package ecosystem provides a declarative dependency file (e.g., `requirements.txt` for Python, `package.json` for npm), use that file to pin versions rather than inline `ARG` + `# renovate:` comments. Renovate has native managers for these formats, which are more reliable than regex matching. Only use `# renovate:` ARG annotations for standalone binary downloads that have no ecosystem dependency file.

## Common Commands

```bash
make build              # Build the devcontainer image (cached)
make up                 # Build and start the devcontainer
make rebuild            # Full rebuild from scratch (no cache)
make down               # Stop and remove the container
make shell              # Open bash shell in running container
make exec CMD="..."     # Run a one-off command in the container
make test               # Run all tests (alias for test-all)
make test-all           # Run all tests (test-tools, test-podman, test-env)
make test-tools         # Verify CLI tools, Python packages, and user config
make test-podman        # Test podman pull, run, and build
make test-env           # Test environment switching functions
make renovate-validate  # Validate renovate.json config
GITHUB_TOKEN=... make renovate-dry-run  # Dry-run Renovate locally

# Base agent image (shared tools and packages)
make base-build         # Build the base agent image
make base-rebuild       # Rebuild base from scratch (no cache)
make base-test          # Run tool verification on the base image

# Claude Code container (UBI10-based, rootless)
make claude-build       # Build the Claude container image (builds base first)
make claude-rebuild     # Rebuild from scratch (no cache)
make claude-test        # Run tool verification in the Claude container
make claude-test-hardened  # Test under full hardening (cap-drop, noexec, limits)
make claude-test-run    # Test claude-run argument assembly (uses mock podman)
make claude-test-all    # Run all Claude container tests
make e2e                # Full end-to-end: rebuild devcontainer + all tests + Claude build/test
claude-run              # Launch Claude in the container (see bin/claude-run)
claude-run -e ocp-rosa  # Launch with resolved cluster credentials
claude-run --shell      # Drop to bash inside the container

# Cursor agent CLI container (UBI10-based, rootless)
make cursor-build       # Build the Cursor agent container image (builds base first)
make cursor-rebuild     # Rebuild from scratch (no cache)
make cursor-test        # Run tool verification in the Cursor agent container
make cursor-test-hardened  # Test under full hardening (cap-drop, noexec, limits)
make cursor-test-run    # Test cursor-run argument assembly (uses mock podman)
make cursor-test-all    # Run all Cursor agent container tests
cursor-run              # Launch Cursor agent in the container (see bin/cursor-run)
cursor-run -e ocp-rosa  # Launch with resolved cluster credentials
cursor-run --shell      # Drop to bash inside the container
```

## Pre-push Requirements

**Do not push changes to the remote unless `make rebuild` followed by `make test` passes locally**, unless the user explicitly asks to push anyway. This ensures CLI tools, podman, and environment switching all work before changes reach `main`.

## Linting

```bash
shellcheck .devcontainer/post-create.sh .devcontainer/post-start.sh .devcontainer/init.sh dotfiles/bashrc
```

## Key Design Decisions

- **Lifecycle hook separation**: Tool installs are cached in Docker layers (Dockerfile) or run once after Features (onCreateCommand). Workspace setup (repo cloning, shell config) runs in postCreateCommand. SSH agent checks run every start via postStartCommand.
- **SSH agent forwarding**: `devcontainer.json` sets `containerEnv.SSH_AUTH_SOCK` to `/tmp/ssh-agent.sock`. The Makefile dynamically mounts the host socket only if it exists (`[ -S "$SSH_AUTH_SOCK" ]`), avoiding errors from stale sockets.
- **Podman-in-container**: Uses `--privileged` with `/dev/fuse` and `/dev/net/tun` devices for nested container support.
- **pip over pipx**: Python packages installed directly via pip since isolation is unnecessary in a disposable container.
- **Read-only mounts**: `~/.ssh`, `~/.gitconfig`, and `~/.config/op` are bind-mounted read-only. GitHub known_hosts must be written to `/etc/ssh/ssh_known_hosts` via `sudo tee`.
- **`podman-docker` required on host**: Cursor's devcontainer extension calls `docker` under the hood.
- **CI compatibility**: `init.sh` creates mount directories on any host (including CI runners). Scripts check `$CI` to skip SSH-dependent operations.
- **Environment switching via `op inject`**: `use <env>` resolves secrets via `op inject` and exports them in the current shell. `unuse <env>` removes them. Both are idempotent. No subshells. See [ADR-0001](adr/0001-environment-switching-with-1password.md).
- **Claude Code native binary**: Installed via `curl https://claude.ai/install.sh` instead of the deprecated npm package, removing the Node.js dependency.
- **No embedded file definitions**: Do not embed large file contents (heredocs, multi-line echo chains, inline Python scripts) inside shell scripts or Dockerfiles. Instead, extract them into standalone files under `dotfiles/` (for runtime config) or alongside the consuming script (for build-time assets like Python merge scripts), then `cp`/`cat`/`COPY` them into place. This keeps generated files lintable, diffable, and editable. Small one-liners and test fixtures are acceptable inline.
