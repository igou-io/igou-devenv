# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a reproducible development environment for homelab infrastructure work. It contains the devcontainer spec and launch scripts for agent containers (whose images are built in `igou-containers`). The actual project code (Kubernetes, Ansible, Terraform, etc.) lives in separate repos cloned into `/workspace/` at container creation time.

## Architecture

```
.devcontainer/
├── Dockerfile           # apt packages, 1Password CLI, CLI binary downloads, claude-code (native)
├── containers-storage.conf  # Podman rootless storage config (COPY'd into image)
├── devcontainer.json    # devcontainer config; Features, lifecycle hooks, editor customizations
├── init.sh              # Host-side initializeCommand: creates mount directories if missing
├── post-create.sh       # Configures shell (.bashrc), writes workspace file
├── post-start.sh        # SSH agent check, Docker socket perms, Claude config restore (every start)
└── requirements.txt     # Pinned Python packages (Ansible ecosystem, yq, mkdocs-material)
dotfiles/
├── .bashrc              # Complete .bashrc copied to ~/.bashrc by post-create.sh
└── homelab.code-workspace  # VS Code workspace file copied to /workspace/
adr/                     # Architecture Decision Records
bin/                     # Custom scripts (symlinked to ~/bin, on PATH)
│   ├── claude-run       # Launch script for the Claude container
│   ├── cursor-run       # Launch script for the Cursor agent container
│   ├── opencode-run     # Launch script for the opencode agent container
│   ├── argocd-refresh-all
│   ├── renovate-validate
│   └── renovate-dry-run
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
| Dockerfile (apt) | python3, podman, buildah, skopeo, jq, 1Password CLI, etc. | `.devcontainer/Dockerfile` |
| Mise (mise.toml + mise.lock) | kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, rclone, direnv, age, node, oc, virtctl, kube-burner, kube-burner-ocp | `mise.toml` (versions), `mise.lock` (per-asset SHA256) |
| Dockerfile (binary downloads) | mise itself (TOFU SHA256), Cursor agent, opencode, Claude Code | `.devcontainer/Dockerfile` (ARG + RUN) |
| pip (onCreateCommand) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |

**Lifecycle hooks** (execution order):

| Hook | Runs on | Script | Purpose |
|---|---|---|---|
| `initializeCommand` | Host | `init.sh` | Creates mount directories before container build |
| `onCreateCommand` | Container | (inline) | `pip install` — runs after Features install Python |
| `postCreateCommand` | Container | `post-create.sh` | Shell config, workspace file |
| `postStartCommand` | Container | `post-start.sh` | SSH agent check, Docker socket perms, Claude config restore (every start) |

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
make e2e                # Full end-to-end: rebuild devcontainer + all tests
claude-run              # Launch Claude in the container (see bin/claude-run)
claude-run -e ocp-rosa  # Launch with resolved cluster credentials
claude-run --shell      # Drop to bash inside the container
cursor-run              # Launch Cursor agent in the container (see bin/cursor-run)
cursor-run -e ocp-rosa  # Launch with resolved cluster credentials
cursor-run --shell      # Drop to bash inside the container
```

### Bumping a CLI tool version

Tools managed by mise (see Architecture table) are pinned in `mise.toml`
with per-asset checksums in `mise.lock`. Renovate handles bumps
automatically. To bump manually:

```bash
# 1. Edit the version in mise.toml
# 2. Regenerate the lockfile
make mise-lock
# 3. Validate the new version still verifies as expected
make test
# 4. Commit mise.toml + mise.lock together
```

If the verification audit (`tests/test-mise.sh`) flags a downgrade
(e.g., aqua-registry switched argocd from SLSA to SHA-only), update
`tests/mise-expected-verification.toml` to match — but only after
confirming the upstream change was deliberate.

## Pre-push Requirements

**Do not push changes to the remote unless `make rebuild` followed by `make test` passes locally**, unless the user explicitly asks to push anyway. This ensures CLI tools, podman, and environment switching all work before changes reach `main`.

## Linting

```bash
shellcheck .devcontainer/post-create.sh .devcontainer/post-start.sh .devcontainer/init.sh dotfiles/.bashrc
```

## Key Design Decisions

- **Lifecycle hook separation**: Tool installs are cached in Docker layers (Dockerfile) or run once after Features (onCreateCommand). Workspace setup (shell config) runs in postCreateCommand. Docker socket permissions and Claude config restore run every start via postStartCommand.
- **Pre-cloned workspaces**: Repos are expected to be pre-cloned on the host at `~/workspace` and bind-mounted into the container. The devcontainer does not clone repos.
- **SSH agent forwarding**: `devcontainer.json` sets `containerEnv.SSH_AUTH_SOCK` to `/tmp/ssh-agent.sock`. The Makefile dynamically mounts the host socket only if it exists (`[ -S "$SSH_AUTH_SOCK" ]`), avoiding errors from stale sockets.
- **Podman-in-container**: Uses `--privileged` with `/dev/fuse` and `/dev/net/tun` devices for nested container support.
- **Host `/dev` bind-mount**: `/dev` is bind-mounted from host to container so USB/serial devices (e.g. `/dev/ttyUSB0`, `/dev/serial/by-id/...`) are accessible without per-device declarations and survive hotplug. Combined with `--privileged`, this gives the container access to all host devices including block devices and `/dev/mem` — acceptable here because the container is single-user homelab tooling.
- **pip over pipx**: Python packages installed directly via pip since isolation is unnecessary in a disposable container.
- **Read-only mounts**: `~/.ssh`, `~/.gitconfig`, and `~/.config/op` are bind-mounted read-only. GitHub known_hosts must be written to `/etc/ssh/ssh_known_hosts` via `sudo tee`.
- **`podman-docker` required on host**: Cursor's devcontainer extension calls `docker` under the hood.
- **CI compatibility**: `init.sh` creates mount directories on any host (including CI runners). Scripts check `$CI` to skip SSH-dependent operations.
- **Environment switching via `op inject`**: `use <env>` resolves secrets via `op inject` and exports them in the current shell. `unuse <env>` removes them. Both are idempotent. No subshells. See [ADR-0001](adr/0001-environment-switching-with-1password.md).
- **Claude Code native binary**: Installed via `curl https://claude.ai/install.sh` instead of the deprecated npm package, removing the Node.js dependency.
- **No embedded file definitions**: Do not embed large file contents (heredocs, multi-line echo chains, inline Python scripts) inside shell scripts or Dockerfiles. Instead, extract them into standalone files under `dotfiles/` (for runtime config) or alongside the consuming script (for build-time assets like Python merge scripts), then `cp`/`cat`/`COPY` them into place. This keeps generated files lintable, diffable, and editable. Small one-liners and test fixtures are acceptable inline.
- **Trust anchors**: Mise is bootstrapped via TOFU SHA256 (the only chicken-and-egg trust anchor for tool installs). Mise then verifies the 21 managed tools via aqua-registry's pinned cosign/SLSA/GPG/SHA256 config. Where aqua-registry's mise install path doesn't run the upstream signature step (helm, terraform, oc), `aqua-registry/<tool>-postinstall.sh` re-runs the GPG verification against a pinned-fingerprint key. The aqua-registry itself is pinned to a specific git SHA, Renovate-bumped, and the bump is gated by `tests/test-mise.sh` which asserts no verification method silently downgraded.
