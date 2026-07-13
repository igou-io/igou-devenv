# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Runs as a devcontainer via Cursor or the `devcontainer` CLI. SSH keys are
loaded on demand from 1Password into a container-local agent (no host agent
forwarding — see [ADR-0004](adr/0004-ssh-keys-from-1password.md)).

## Execution Models

This repo has multiple execution models with different capabilities:

- local full devcontainer via Cursor Dev Containers or `make up`
- lightweight published-image path via `make run`
- local wrapper-launched agent containers via `claude-run`, `cursor-run`, and
  `opencode-run`
- Hermes docker-terminal containers
- CI/build containers

Do not assume those models share privilege, persistence, nested Podman, Docker
socket access, `/dev` mounts, credential handling, or sandbox support. See
[docs/execution-models.md](docs/execution-models.md) and [AGENTS.md](AGENTS.md)
before making runtime capability claims.

## What's Inside

**Kubernetes:** kubectl, helm, kustomize, ArgoCD CLI, kubeseal, flux, virtctl,
kubeconform, kind, kube-burner, kube-burner-ocp, tkn (Tekton)

**Infrastructure:** Terraform, SOPS, age, rclone

**Ansible:** ansible, ansible-navigator, ansible-builder,
ansible-runner, ansible-lint

**OpenShift:** oc CLI

**Container Tooling:** podman, buildah, skopeo in the local full devcontainer
(which runs privileged for nested container support), Docker CLI via host socket
in that same full devcontainer path

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
mechanism. See [AGENTS.md](AGENTS.md) for the per-layer Renovate strategy.

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

1. **Docker** installed with the daemon running — the devcontainer is always
   launched privileged via Docker:
   ```bash
   sudo systemctl enable --now docker
   sudo usermod -aG docker "$USER"   # then re-login so `docker` works without sudo
   ```
2. **1Password credentials on the host** (see item 5 below) — SSH keys are
   pulled from 1Password inside the container with `ssh-use`; no host
   ssh-agent or on-disk private key is needed.
3. **Repos pre-cloned on the host** at `~/workspace/`:
   ```bash
   mkdir -p ~/workspace
   for repo in igou-kubernetes igou-ansible igou-infrastructure igou-openshift igou-containers igou-inventory igou-kubernetes-private; do
       git clone "git@github.com:igou-io/${repo}.git" ~/workspace/${repo}
   done
   ```
4. **Cursor** with the **Dev Containers** extension, or the **devcontainer CLI**:
   ```bash
   npm install -g @devcontainers/cli
   ```
5. Your credentials in the standard locations:
   - `~/.ssh/` — SSH config and known_hosts (no private keys; keys live in
     1Password and are loaded per-session with `ssh-use`)
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

`make up` is not a from-scratch build: `devcontainer.json` sets
`cacheFrom: ghcr.io/igou-io/igou-devenv`, so it pulls the published image and
reuses its layers. The image is **public**, so no `docker login` is needed.

### Run via pull (no build)

To skip building entirely and just get the browser IDE on a folder, pull and run
the published image directly. The package is public, so this needs **no login**:

```bash
make run                 # opens the current dir in code-server at http://localhost:8080
make run DIR=~/code      # open a different folder
make run TAG=2026.06.15-3 PORT=8443 PASSWORD=hunter2   # pin a release, port, password
```

`make run` prints a generated password and starts code-server in the foreground
(Ctrl-C to stop; the container is removed on exit). It's the raw equivalent of:

```bash
docker run --rm -it --user igou \
  -e HOME=/home/igou -e PASSWORD=hunter2 \
  -p 8080:8080 -v "$PWD:/workspace:Z" \
  ghcr.io/igou-io/igou-devenv:2026.06.15-3 \
  code-server --bind-addr 0.0.0.0:8080 /workspace
```

This is a lightweight, **ephemeral** path: code-server settings/extensions and
the password are not persisted. It also does not imply the same privileged
runtime, lifecycle hooks, host config mounts, Docker socket, `/dev` bind mount,
or nested Podman/buildah capability as the full devcontainer. For the full,
persistent environment (always-on code-server, 1Password, kubeconfig,
nested Podman/buildah, libvirt) use `make up` or Cursor. Pin a `:YYYY.MM.DD` tag
for reproducibility; `:latest` tracks the most recent green build on `main`.

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
use ocp                 # activate the OpenShift cluster in the current shell
use ansible             # stack Ansible vault on top
unuse ansible           # remove Ansible vault environment
unuse ocp               # back to clean shell

use quay                # authenticate podman/docker to quay.io
podman pull quay.io/igou/some-private-image
unuse quay              # deletes the temp auth file

k8s-unset               # clear KUBECONFIG and K8S_AUTH_* vars
```

Environment files live in `envs/` and contain only `op://` references — no
secrets are stored in the repo.

Env files with `REGISTRY_HOST`, `REGISTRY_USERNAME`, and `REGISTRY_PASSWORD`
write a temp `containers-auth.json` and export `REGISTRY_AUTH_FILE` (podman,
buildah, skopeo) plus `DOCKER_CONFIG` (docker), so container CLIs are
authenticated for the shell session without `podman login` state on disk.
See `envs/quay.env` for the shape.

## GitHub Authentication (ghapp)

GitHub auth uses **runtime-minted, repo-scoped GitHub App tokens** (`ghapp`)
rather than static Personal Access Tokens. Every token is bound to a **single
repository**, carries only the permissions the operation needs, expires within
an hour, and is never written to disk — the App private key is read from
1Password (`op read`) at mint time.

This replaces the old `use claude-david-igou-github-token` / `use
claude-igou-io-github-token` PAT flow. Those env files still exist but are
**deprecated** (kept only as a fallback for gaps the App's permission ceiling
can't cover, e.g. writing Actions secrets).

The App (`igou-dev`) is installed on both accounts; the owner half of
`OWNER/REPO` picks the installation, so `david-igou/*` and `igou-io/*` both work
from one config (`~/.config/ghapp/config.yaml`, seeded by `post-create.sh`).

Three ways to authenticate:

```bash
# 1. Plain git over HTTPS — just works. The ghapp credential helper (baked into
#    /etc/gitconfig) mints a contents:write token for exactly the repo pushed.
git clone https://github.com/igou-io/igou-ansible.git
git -C igou-ansible push

# 2. gh, scoped to one repo — nothing exported into your shell:
gh-app --repo igou-io/igou-devenv -- pr list
gh-app --repo david-igou/ansible-collection-devhost --permission contents=read -- release list

# 3. Export a fresh repo-scoped GH_TOKEN into the current shell (for tools that
#    read GH_TOKEN and can't use gh-app), then clear it:
ght igou-io/igou-ansible          # default permissions
ght david-igou/hermes contents=read
ght-unset
```

Other entry points from the same identity: `git-app --repo OWNER/REPO -- push
...` (askpass variant, no helper needed), `ghapp token --repo OWNER/REPO
[--permission NAME=LEVEL]` (print a raw token), `ghapp api /repos/OWNER/REPO/...`,
and `ghapp doctor --repo OWNER/REPO` (diagnostics). `--repo` is required
anywhere a token is minted — tokens are per-repository by design, so there is no
org-wide token.

> SSH remotes bypass the App identity — use HTTPS remotes for App-authenticated
> (bot) work. `op` must be authenticated in the shell (it is by default via the
> bind-mounted `~/.config/op`), since the private key is fetched from 1Password
> on every mint.

The host side of this (the devenv VM / physical devhost) installs the same
`ghapp` CLI and credential helper via the `david_igou.devhost.ghapp` role in
`igou-ansible`'s `playbooks/devenv/bootstrap.yml`.

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
| `make test-sandbox-primitives` | Diagnostic user-namespace and bubblewrap smoke test; runtime failures are non-fatal unless `REQUIRE_SANDBOX_PRIMITIVES=true` |
| `make test-podman` | Test podman pull, run, and build |
| `make test-env` | Test environment switching functions |
| `make test-mise` | Audit mise-managed tools' verification methods against `tests/mise-expected-verification.toml` |
| `make test-mise-lockfile` | Verify `mise.lock` is in sync with `mise.toml` (host mise, else a throwaway `ghcr.io/jdx/mise` container) |
| `make mise-lock` | Regenerate `mise.lock` against the current `mise.toml` (uses `ghcr.io/jdx/mise`; run inside the devcontainer or CI; atomic restore on failure) |
| `make clean` | Down + prune dangling images |
| `make renovate-validate` | Validate `renovate.json` config |
| `make renovate-dry-run` | Dry-run Renovate locally (requires `GITHUB_TOKEN`) |
| `make sbom` | Generate SBOMs (SPDX + CycloneDX) for the built devcontainer image |
| `make opencode-build` | Build the opencode container image from `../igou-containers/apps/opencode/` |
| `make e2e` | Full end-to-end: rebuild devcontainer + run all tests |

Local agent-container images (Claude, Cursor, opencode) are built and published
by [`igou-containers`](https://github.com/igou-io/igou-containers), not this
repo. The `claude-run`, `cursor-run`, and `opencode-run` launcher scripts in
`bin/` pull and run those images from the local full devcontainer or another
environment with working rootless Podman.

## Agent Containers (Claude, Cursor, opencode)

These are local-development convenience wrappers launched from the full
devcontainer. They are not the Hermes execution model.

The wrapped UBI10-based images run coding-agent sessions against infrastructure
repos with selective per-session credential injection. **Images are built and
published by [`igou-containers`](https://github.com/igou-io/igou-containers);
this repo ships only the launcher scripts and `bin/` entry points.**

Hermes uses its docker-terminal setting to enter a configured rootless Podman
container. Do not assume Hermes uses these wrappers unless someone explicitly
wires Hermes to call them and verifies that path.

### Usage

```bash
claude-run                          # launch claude with current directory mounted
claude-run -e ocp-rosa              # resolve ocp-rosa secrets, inject as env vars
claude-run -e ocp -e ansible        # stack multiple environments
claude-run --shell                  # drop to bash instead of claude
claude-run -e aws -- --resume       # pass flags through to claude

cursor-run                          # same shape — launches the Cursor agent
opencode-run                        # same shape — launches opencode
```

Credentials are resolved via `op inject` in the devcontainer before being
passed as plain environment variables to the agent container. The agent
container never has direct access to 1Password.

### Differences from the devcontainer

| | Local full devcontainer | Local wrapper-launched agent containers |
|---|---|---|
| Base image | CentOS Stream 10 | UBI10 (`ubi-micro` for Claude, `ubi-minimal` for Cursor/opencode) |
| Container engine inside | podman, buildah, skopeo, Docker CLI | None (no nested containers) |
| Privileged mode | Yes (for nested podman) | No (rootless via `--userns=keep-id`) |
| Hardening | General-purpose trusted workstation container; not a sandbox | Wrapper flags such as `--cap-drop=ALL` and noexec `/tmp`; tool-specific sandboxing only where that tool supports it and runtime tests pass |
| OpenCode isolation | Outer container only | OpenCode permissions are UX guardrails, not OS isolation |
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

## SSH Keys from 1Password

There is no host SSH agent forwarding and no private key on disk (see
[ADR-0004](adr/0004-ssh-keys-from-1password.md)). `post-start.sh` starts an
**empty** container-local ssh-agent on `/tmp/ssh-agent.sock` (the fixed path
`devcontainer.json` exports as `SSH_AUTH_SOCK`); every terminal shares it.
Keys are stored as native SSH Key items in 1Password and loaded on demand:

```bash
ssh-use                  # load the default key (op://lab_ssh/github)
ssh-use lab-nodes        # load a different item from the vault
SSH_USE_TTL=1h ssh-use   # override the default 12h agent lifetime
ssh-add -l               # audit what's loaded
ssh-unuse github         # remove one key
ssh-unuse                # remove all keys
```

The private key is piped from `op read` straight into agent memory — it never
touches a file — and expires from the agent after the TTL. Editor reconnects
have no effect on SSH, and headless/tmux sessions work without an editor
attached. `~/.ssh` remains bind-mounted for `config`, `known_hosts`, and
`authorized_keys` only.

## Container Tooling

The local full devcontainer runs in `--privileged` mode, enabling podman to run
containers natively inside that specific model:

```bash
podman build -t myimage .
podman run --rm myimage
buildah bud -t myimage .
```

Podman is configured with `fuse-overlayfs` for storage and `slirp4netns` for
rootless networking in the full devcontainer. Docker CLI is also available there
via the host socket (docker-outside-of-docker Feature). Do not infer nested
Podman, host Docker socket access, or `/dev` access for `make run`, Hermes, CI,
or wrapper-launched agent containers without testing that exact runtime.

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

CI should hard-fail when required packages or commands are missing. Runtime
namespace and bubblewrap capability checks are diagnostic by default because CI
does not necessarily provide those kernel/runtime capabilities.

## Customization

### Adding Tools

- **CLI binaries managed by `mise`** (preferred for new tools) → add to `mise.toml`, run `make mise-lock`, commit both. If the tool isn't in aqua-registry, use the `http:` backend with explicit per-platform URLs (see existing entries for `virtctl`, `kube-burner`, etc.). If the tool needs additional GPG verification beyond aqua-registry's defaults, add a postinstall hook in `aqua-registry/<tool>-postinstall.sh` (see `oc-postinstall.sh` for the pattern) and update `tests/mise-expected-verification.toml` to `"postinstall-gpg"`.
- **dnf packages** → add to `.devcontainer/Dockerfile` (under the existing `dnf install` block)
- **Python packages** → add to `.devcontainer/requirements.txt` (pinned for Renovate)
- **Binaries not in aqua-registry that need custom verification logic** (Claude Code, Cursor agent, opencode pattern) → add a dedicated `ARG <NAME>_VERSION` + `RUN` block in `.devcontainer/Dockerfile` with a `# renovate:` comment. Keep these rare — prefer mise's `http:` backend when possible.
- **Custom scripts** → add to `bin/` (symlinked to `~/bin`, on PATH)
- **Cursor extensions** → add to `customizations.vscode.extensions` in `devcontainer.json`

Hermes dependencies must be added to the image Hermes actually enters. Patching
only the local wrapper-launched agent images, or only these wrapper scripts, does
not make that dependency available to Hermes.

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

Credentials are bind-mounted from the host. `.gitconfig` and `~/.config/op`
are read-only; kubeconfig is read-write for context switching. SSH private
keys are not on disk at all — they live in 1Password and are loaded into the
container-local agent per-session (ADR-0004). The container never stores
secrets in its image layers.

## Reprovisioning the Host

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fedora/RHEL
sudo dnf install -y docker openssh-server
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # re-login so docker works without sudo

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.config/op ~/.config/opencode ~/.terraform.d ~/.claude
echo '{}' > ~/.claude.json
touch ~/.gitconfig

echo "Host ready. Clone devenv and open with: cursor ~/igou-devenv"
```

## Troubleshooting

### SSH

**SSH operations fail with "Permission denied (publickey)":**
```bash
ssh-add -l          # what does the agent hold?
ssh-use             # (re)load the key — it may have hit its TTL
```

**"Could not open a connection to your authentication agent" / dead socket:**
```bash
ensure-ssh-agent    # restart the container-local agent, then ssh-use again
```
A container created before ADR-0004 may still have the old host socket
bind-mounted at `/tmp/ssh-agent.sock`; recreate it with `make down && make up`.

**`ssh-use` fails to resolve the key:** check 1Password auth (`op vault list`)
and that the item exists: `op read "op://lab_ssh/github/public key"`.

### Docker

**Cannot connect to the Docker daemon:**
```bash
sudo systemctl status docker
sudo usermod -aG docker "$USER"   # then re-login
docker info
```

### Cursor + Devcontainers

**"Reopen in Container" not appearing:** Open command palette (Ctrl+Shift+P) →
`Dev Containers: Reopen in Container`

**Extensions missing after connecting:** Command palette → **Dev Containers: Rebuild Container**.

### Environment Switching

**`use` hangs:** Set `BASHRC_DEBUG=1` before the `use` call to trace shell
startup and identify which `.bashrc` section is blocking:
```bash
BASHRC_DEBUG=1 use ocp
```
