# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Runs as a devcontainer via Cursor or the `devcontainer` CLI, with SSH agent
forwarding.

## What's Inside

**Kubernetes:** kubectl, helm, kustomize, ArgoCD CLI, kubeseal, flux, virtctl,
kubeconform, kind, kube-burner, kube-burner-ocp, tkn (Tekton)

**Infrastructure:** Terraform, SOPS, age, rclone

**Ansible:** ansible, ansible-navigator, ansible-builder,
ansible-runner, ansible-lint

**OpenShift:** oc CLI

**Container Tooling:** podman, buildah, skopeo (native in container, runs
privileged for nested container support), Docker CLI (via host socket)

**CI/CD:** GitHub CLI, act (local GitHub Actions)

**General:** 1Password CLI, jq, yq, direnv, shellcheck, yamllint, make,
tree, nmap, tmux, vim, htop, node

**AI agent CLIs:** Claude Code (`claude`), Cursor agent (`cursor-agent`, alias `agent`),
opencode (`opencode`) — each pinned + cryptographically verified at build time

**Browser IDE:** code-server (browser-based VS Code) — started always-on by
`post-start.sh`, password-authenticated, served on port `8080`
(see [Browser IDE (code-server)](#browser-ide-code-server))

### How Tools Are Installed

CLI tooling is split across four layers, each with its own version-pinning
mechanism. See [CLAUDE.md](CLAUDE.md) for the per-layer Renovate strategy.

| Layer | What | Where to add |
|---|---|---|
| Dockerfile (dnf) | podman, buildah, skopeo, jq, direnv, gpg2, 1Password CLI, Docker CLI, base utilities | `.devcontainer/Dockerfile` |
| Mise (`mise.toml` + `mise.lock`) | kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, rclone, direnv, age, node, oc, virtctl, kube-burner, kube-burner-ocp, code-server | `mise.toml` (versions) + `mise.lock` (per-asset checksums) |
| Dockerfile (binary downloads) | mise itself (GPG-signed checksums — trust anchor), Claude Code, Cursor agent, opencode | `.devcontainer/Dockerfile` (ARG + RUN) |
| pip (onCreateCommand) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |

**Verification floor for mise-managed tools** (asserted by
`tests/test-mise.sh` against `tests/mise-expected-verification.toml`):

- **GPG (pinned fingerprint, via `aqua-registry/<tool>-postinstall.sh`)**: helm, terraform, oc
- **SLSA L3 attestation + sha256**: flux2, sops, argocd
- **sha256** (upstream-published checksums): kubectl, gh, kustomize, kubeseal, kubeconform, kind, act, tkn, rclone, direnv, age
- **blake3 TOFU** (mise lockfile pin, no upstream-signed checksums available): node, virtctl, kube-burner, kube-burner-ocp, code-server

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
4. **SSH agent running with your key loaded** (for operations that need SSH
   access inside the container):
   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519   # or whichever key has GitHub access
   ```
5. **Repos pre-cloned on the host** at `~/workspace/`:
   ```bash
   mkdir -p ~/workspace
   for repo in igou-kubernetes igou-ansible igou-infrastructure igou-openshift igou-containers igou-inventory igou-kubernetes-private; do
       git clone "git@github.com:igou-io/${repo}.git" ~/workspace/${repo}
   done
   ```
6. **Cursor** with the **Dev Containers** extension, or **devcontainer CLI**:
   ```bash
   npm install -g @devcontainers/cli
   ```
7. **Cursor setting** to use podman — in Settings, set `dev.containers.dockerPath`
   to `podman`.
8. Your credentials in the standard locations:
   - `~/.ssh/` — SSH keys and config
   - `~/.kube/` — Kubernetes configs
   - `~/.gitconfig` — Git identity (mounted read-only)
   - `~/.config/argocd/` — ArgoCD CLI config
   - `~/.config/op/connect-host` + `~/.config/op/connect-token` — 1Password
     Connect host URL and token (preferred auth)
   - `~/.config/op/service-account-token` — 1Password service account token
     (fallback when Connect creds are absent)
   - `~/.config/opencode/` — opencode config (bind-mounted into devcontainer + opencode container)
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
- Configures `.bashrc` with prompt, environment switching, aliases, and direnv
- Symlinks `bin/` into `~/bin` (on PATH) for custom scripts
- Creates a `homelab.code-workspace` file

Repos are pre-cloned on the host at `~/workspace/` and bind-mounted into
the container. Your repos will be at:
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
| `make restart` | Recreate the devcontainer without rebuilding the image |
| `make rebuild` | Full rebuild from scratch (no cache) |
| `make down` | Stop and remove the container |
| `make shell` | Open a bash shell in the running container |
| `make exec CMD="..."` | Run a one-off command in the container |
| `make test` | Run all tests (alias for `test-all`) |
| `make test-tools` | Verify CLI tools, Python packages, and user config |
| `make test-podman` | Test podman pull, run, and build |
| `make test-env` | Test environment switching functions |
| `make test-mise` | Audit mise-managed tools' verification methods against `tests/mise-expected-verification.toml` |
| `make test-mise-lockfile` | Verify `mise.lock` is in sync with `mise.toml` (runs on host via podman) |
| `make mise-lock` | Regenerate `mise.lock` against the current `mise.toml` (uses `ghcr.io/jdx/mise` via podman; atomic restore on failure) |
| `make clean` | Down + prune dangling images |
| `make renovate-validate` | Validate `renovate.json` config |
| `make renovate-dry-run` | Dry-run Renovate locally (requires `GITHUB_TOKEN`) |
| `make sbom` | Generate SBOMs (SPDX + CycloneDX) for the built devcontainer image |
| `make opencode-build` | Build the opencode container image from `../igou-containers/apps/opencode/` |
| `make e2e` | Full end-to-end: rebuild devcontainer + run all tests |

Agent-container images (Claude, Cursor, opencode) are built and published by
[`igou-containers`](https://github.com/igou-io/igou-containers), not this repo.
The `claude-run` / `cursor-run` / `opencode-run` launcher scripts in `bin/`
pull and run those images.

## Agent Containers (Claude, Cursor, opencode)

Three hardened UBI10-based images for running coding-agent sessions against
infrastructure repos, each launched from inside the devcontainer with
selective per-session credential injection. **Built and published by
[`igou-containers`](https://github.com/igou-io/igou-containers); this repo
just ships the launcher scripts and the `bin/` entry points.**

### Usage

```bash
claude-run                          # launch claude with current directory mounted
claude-run -e ocp-rosa              # resolve ocp-rosa secrets, inject as env vars
claude-run -e ocp-hub -e ansible    # stack multiple environments
claude-run --shell                  # drop to bash instead of claude
claude-run -e aws -- --resume       # pass flags through to claude

cursor-run                          # same shape — launches the Cursor agent
opencode-run                        # same shape — launches opencode
```

Credentials are resolved via `op inject` in the devcontainer before being
passed as plain environment variables to the agent container. The agent
container never has direct access to 1Password.

### Differences from the devcontainer

| | Devcontainer | Agent containers |
|---|---|---|
| Base image | CentOS Stream 10 | UBI10 (`ubi-micro` for Claude, `ubi-minimal` for Cursor/opencode) |
| Container engine inside | podman, buildah, skopeo, Docker CLI | None (no nested containers) |
| Privileged mode | Yes (for nested podman) | No (rootless via `--userns=keep-id`) |
| Hardening | None (general-purpose) | `--cap-drop=ALL`, noexec `/tmp`, bubblewrap + seccomp sandbox |
| Launched via | Cursor / `make up` | `claude-run` / `cursor-run` / `opencode-run` from inside devcontainer |

### opencode-specific: pointing at the local Qwen endpoint

`opencode-run` is the same shape as the other two launchers but is
typically pointed at the Qwen3.6-35B-A3B endpoint hosted by
`applications/llmkube/` in `igou-openshift` (or any OpenAI-compatible
endpoint). The launcher bind-mounts `~/.config/opencode/` (config) and
`~/.local/share/opencode/` (auth tokens, session history) so state persists
across container runs and is shared with the devcontainer.

`make opencode-build` is provided for fast local iteration on the image
before pushing to `igou-containers` — the GHCR copy is produced by the
`igou-containers` workflow on every push to its `main`.

Example `~/.config/opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama.cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (igou.systems)",
      "options": {
        "baseURL": "https://qwen3-35b-a3b-llmkube-system.apps.ocp.igou.systems/v1"
      },
      "models": {
        "qwen3.6-35b-a3b": {
          "name": "Qwen3.6-35B-A3B (local)",
          "limit": { "context": 65536, "output": 32768 },
          "reasoning": true,
          "tools": true,
          "temperature": true,
          "options": { "temperature": 0.7, "top_p": 0.8 }
        }
      }
    }
  },
  "model": "llama.cpp/qwen3.6-35b-a3b"
}
```

The InferenceService is scaled to 0 by default — scale up before use:

```bash
oc patch inferenceservice qwen3-35b-a3b -n llmkube-system \
  --type merge -p '{"spec":{"replicas":1}}'
```

See `applications/llmkube/README.md` in `igou-openshift` for the full server-side
tuning rationale (flash attention, q8 KV cache, jinja chat template, etc.).

## SSH Agent Forwarding

**Via Cursor:** The devcontainer bind-mounts `SSH_AUTH_SOCK` from the host into
the container at `/tmp/ssh-agent.sock`. Cursor handles this when you have
`ForwardAgent yes` in your SSH config.

**Via Makefile:** The `make up`/`make rebuild` commands detect your
`SSH_AUTH_SOCK` and pass it via `--mount` and `--remote-env`. If the socket
doesn't exist (stale agent, different terminal), it's silently skipped.

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

## Browser IDE (code-server)

[code-server](https://github.com/coder/code-server) (browser-based VS Code) is
installed via mise and started **always-on** by `post-start.sh` on every
container start. It serves on port **8080**.

**Access it:**

```bash
# Get the password (generated on first start, persisted in the config)
cat ~/.config/code-server/config.yaml   # look for the `password:` line

# Then open http://<host>:8080 in a browser and log in.
```

Because the container runs with `--network=host`, port 8080 is published
directly on the host's network — no port forwarding needed. From another
machine, reach it over your existing SSH/Tailscale path to the host.

**Security — read this.** The container is `--privileged` with `/dev`
bind-mounted, so anyone who reaches the code-server port gets a terminal with
**full host access**. It is bound to `0.0.0.0`, so:

- Password authentication is **mandatory** and configured by default
  (`auth: password`). Never set `auth: none`.
- Prefer reaching it over an SSH tunnel or Tailscale rather than exposing
  `:8080` to an untrusted network.
- To pin a known password (instead of the generated one), set the `PASSWORD`
  (or `HASHED_PASSWORD`) environment variable before code-server starts — it
  overrides the config. e.g. source it via the `use` / `op` flow.

**Config** lives at `~/.config/code-server/config.yaml`, seeded from
[`dotfiles/code-server-config.yaml`](dotfiles/code-server-config.yaml) by
`post-create.sh` on first run only. Both `~/.config/code-server` and
`~/.local/share/code-server` are bind-mounted from the host, so the config
(including the generated password), installed extensions, and editor settings
**persist across image rebuilds** — the password is generated once and reused.
To force a fresh config, delete `~/.config/code-server/config.yaml` on the host
and restart.

**Extensions** come from the [Open VSX](https://open-vsx.org/) registry, not
Microsoft's marketplace, so the set available in the browser differs from
Cursor/VS Code (Red Hat Ansible and HashiCorp Terraform are on Open VSX;
some Microsoft-owned extensions are not).

## Dependency Management (Renovate)

All tool versions are pinned and managed by [Renovate](https://docs.renovatebot.com/):

- **Dockerfile base image** — pinned by digest, updated by Renovate's Docker manager
- **Mise-managed CLI tools** (21 binaries) — pinned in `mise.toml`, per-asset checksums in `mise.lock`. Renovate's native `mise` manager bumps versions; because the hosted Mend app cannot run `postUpgradeTasks`, its PRs are stale and fail the `mise-lockfile-check` guard until you regenerate the lock with `make mise-lock` and push.
- **aqua-registry pin** — the upstream registry that mise consumes is pinned to a specific git SHA in `mise.toml`. Renovate bumps it; `tests/test-mise.sh` gates the bump by asserting no per-tool verification method silently downgraded.
- **Mise itself** + Claude Code + Cursor agent + opencode — pinned in `.devcontainer/Dockerfile` ARG blocks with `# renovate:` comments and the `github-releases` datasource (custom regex manager). Verified at build time: mise and Claude Code via pinned-fingerprint GPG signatures, Cursor agent and opencode via SHA256.
- **Python packages** — pinned in `.devcontainer/requirements.txt`, updated by `pip_requirements` manager.

Trust anchors (mise itself, aqua-registry pin) are routed into their own
Renovate groups in `renovate.json` so they get reviewed separately from
routine tool bumps.

To test Renovate config locally:
```bash
make renovate-validate                     # validate config syntax
GITHUB_TOKEN=ghp_... make renovate-dry-run # see what would be updated
```

### Weekly release

A Monday pipeline cuts a dated release of the devcontainer:

- `release-prepare.yaml` (06:30 UTC) regenerates `mise.lock` on the week's
  Renovate mise PR and enables GitHub auto-merge (it can't merge itself — the
  hosted app can't regenerate the lock); GitHub merges it once `build` passes.
- `release.yaml` (08:00 UTC) promotes the tested `:latest` digest to
  `ghcr.io/igou-io/igou-devenv:YYYY.MM.DD` (no rebuild — byte-identical to what
  CI tested), tags `vYYYY.MM.DD`, and creates a GitHub Release with notes + SBOM.

`:latest` tracks `main` via `build.yaml` (which builds + tests + pushes it on
every push to `main`); the `:YYYY.MM.DD` tags are immutable weekly snapshots —
promoted from that same tested `:latest` digest — to pin or roll back to. Needs
the `RELEASE_PAT` secret.

`release.yaml` can also be run on demand (`gh workflow run release.yaml`):
`-f dry_run=true` for resolve+plan only, or `-f version=0.0.0-test -f force=true`
to cut a throwaway test promotion.

## CI

GitHub Actions builds the devcontainer on every push and PR to `main` using
[devcontainers/ci](https://github.com/devcontainers/ci). The workflow builds
the full image (Dockerfile + Features + lifecycle hooks) and runs the full
test suite (`tests/run-all.sh`) inside the container.

## Customization

### Adding Tools

- **CLI binaries managed by `mise`** (preferred for new tools) → add to `mise.toml`, run `make mise-lock`, commit both. If the tool isn't in aqua-registry, use the `http:` backend with explicit per-platform URLs (see existing entries for `virtctl`, `kube-burner`, etc.). If the tool needs additional GPG verification beyond aqua-registry's defaults, add a postinstall hook in `aqua-registry/<tool>-postinstall.sh` (see `oc-postinstall.sh` for the pattern) and update `tests/mise-expected-verification.toml` to `"postinstall-gpg"`.
- **dnf packages** → add to `.devcontainer/Dockerfile` (under the existing `dnf install` block)
- **Python packages** → add to `.devcontainer/requirements.txt` (pinned for Renovate)
- **Binaries not in aqua-registry that need custom verification logic** (Claude Code, Cursor agent, opencode pattern) → add a dedicated `ARG <NAME>_VERSION` + `RUN` block in `.devcontainer/Dockerfile` with a `# renovate:` comment. Keep these rare — prefer mise's `http:` backend when possible.
- **Custom scripts** → add to `bin/` (symlinked to `~/bin`, on PATH)
- **Cursor extensions** → add to `customizations.vscode.extensions` in `devcontainer.json`

### 1Password Integration

The 1Password CLI authenticates via **1Password Connect**
(`OP_CONNECT_HOST` + `OP_CONNECT_TOKEN`), sourced from
`~/.config/op/connect-host` and `~/.config/op/connect-token`
(bind-mounted read-only from the host). It falls back to
`OP_SERVICE_ACCOUNT_TOKEN` (`~/.config/op/service-account-token`) when the
Connect creds are absent. Connect reads hit the self-hosted server, so
they aren't subject to the 1password.com service-account API rate limit.

Use the `use` function for environment switching — see
[ADR-0001](adr/0001-environment-switching-with-1password.md) and
[ADR-0003](adr/0003-default-to-1password-connect.md).

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

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.config/op ~/.config/opencode ~/.terraform.d ~/.claude
echo '{}' > ~/.claude.json
touch ~/.gitconfig

echo "Host ready. Clone devenv and open with: cursor ~/igou-devenv"
```

## Troubleshooting

### SSH Agent Forwarding

**SSH operations fail with "Permission denied (publickey)":**
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
