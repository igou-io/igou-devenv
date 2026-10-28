# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Runs as a devcontainer via Cursor or the `devcontainer` CLI. SSH keys are
loaded on demand from 1Password into a container-local agent (no host agent
forwarding — see [ADR-0004](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Environment%20and%20Credential%20Decisions.md)).

## Execution Models

This repo has multiple execution models with different capabilities:

- local full devcontainer via Cursor Dev Containers or `make up`
- lightweight published-image path via `make run`
- Hermes docker-terminal containers
- OpenShift Dev Spaces workspace on the ocp cluster via `devfile.yaml`
- CI/build containers

Do not assume those models share privilege, persistence, nested Podman, Docker
socket access, `/dev` mounts, credential handling, or sandbox support. See
[igou-docs/devenv/Devenv Runtime Models and Capability Validation.md](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Runtime%20Models%20and%20Capability%20Validation.md) and [AGENTS.md](AGENTS.md)
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
| Dockerfile (dnf) | podman, buildah, skopeo, jq, gnupg2, 1Password CLI, Docker CLI, base utilities | `.devcontainer/Dockerfile` |
| Mise (`mise.toml` + `mise.lock`) | kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, tkn-pac, rclone, direnv, age, node, oc, virtctl, kube-burner, kube-burner-ocp, openshell, code-server, rc, t3, gws | `mise.toml` (versions) + `mise.lock` (per-asset checksums) |
| Dockerfile (binary downloads) | mise itself (GPG-signed checksums — trust anchor), Claude Code, Cursor agent, opencode | `.devcontainer/Dockerfile` (ARG + RUN) |
| Dockerfile (pip) | Ansible ecosystem, yq, Kubernetes and API client libraries | `.devcontainer/requirements.txt` |

Released Fedora supplies native Python for `python`, `python3`, and pip tooling. The current baseline is Fedora 44 and Python 3.14. Each image build pulls the current base, disables layer caching, and refreshes distro packages. Python/Ansible versions, RPM versions, and dependency-check results appear in the build log. Python has no source installer, custom Renovate feed, or runtime manifest.

| Branch | Ansible Core | Published image tag |
| --- | --- | --- |
| `main` | Latest stable release, currently 2.21.5 | `ghcr.io/igou-io/igou-devenv:latest` |
| `devel` | Published alpha/beta/RC releases | `ghcr.io/igou-io/igou-devenv:devel` |

Both branches use stable Fedora and its native Python. Renovate checks both
branches, excludes Core prereleases on `main`, and allows them on `devel`.
Fedora release numbers come from the built-in endoflife-date datasource;
image digests are not pinned. Core and Fedora upgrades require review.
The existing tests and CI gate apply to both channels. To run the preview
image, use `make up-release TAG=devel` or `make run TAG=devel`.

Python requirements are installed during the image build. Rebuild the image
after changing `.devcontainer/requirements.txt`.

**Verification floor for mise-managed tools** (asserted by
`tests/test-mise.sh` against `tests/mise-expected-verification.toml`):

- **GPG (pinned fingerprint, via `aqua-registry/<tool>-postinstall.sh`)**: helm, terraform, oc
- **SLSA L3 attestation + sha256**: flux2, sops, argocd
- **sha256** (upstream-published checksums): kubectl, gh, kustomize, kubeseal, kubeconform, kind, act, tkn, rclone, direnv, age
- **blake3 TOFU** (mise lockfile pin, or upstream checksums not consumed by the `http:` backend): node, virtctl, kube-burner, kube-burner-ocp, openshell, code-server, rc, gws

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

When an image is built, `devcontainer.json` passes `--pull --no-cache` so the
build refreshes Fedora packages. Starting an existing container reuses that
container; use `make rebuild` to recreate it with current packages.

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
- Configures `.bashrc` (prompt, aliases, direnv) and installs `~/.bashrc.d/` (`use`/`unuse`, `ssh-use`/`ssh-unuse`, `ght`) — sourced for every shell, interactive or not
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
1Password for secret resolution. See [ADR-0001](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Environment%20and%20Credential%20Decisions.md)
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

Resolution is implemented in `bin/resolve-profile` and used by `use` and
the in-cluster `AGENT_PROFILE` hook. It prints `KEY=VALUE`
lines (plus temp-file paths for `KUBECONFIG` / `REGISTRY_AUTH_FILE`) and is
atomic: on any failure nothing is printed and no temp files remain.

```bash
resolve-profile --list                    # same as `use` with no args
resolve-profile ocp-cluster-reader        # KEY=VALUE lines; KUBECONFIG=/tmp/kubeconfig.XXXX
resolve-profile rk8s ansible              # stack profiles (later wins)
IGOU_ENVDIR=/other/envs resolve-profile x # alternate env directory (tests use this)
```

Env files with `REGISTRY_HOST`, `REGISTRY_USERNAME`, and `REGISTRY_PASSWORD`
write a temp `containers-auth.json` and export `REGISTRY_AUTH_FILE` (podman,
buildah, skopeo) plus `DOCKER_CONFIG` (docker), so container CLIs are
authenticated for the shell session without `podman login` state on disk.
See `envs/quay.env` for the shape.

### Non-interactive shells (agents and scripts)

The shell functions (`use`, `unuse`, `ssh-use`, `ssh-unuse`, `ght`, `k8s-unset`,
`ansible-unset`) live in `dotfiles/.bashrc.d/*.sh`, installed to `~/.bashrc.d/` by
`post-create.sh`. `.bashrc` sources that directory *before* its interactive-only
early return, so agent tool calls and scripts get them without `bash -i`:

```bash
bash -c 'use ocp-cluster-reader && oc get nodes'   # one call; the env dies with the shell
bash -c 'ssh-use ansible'                          # persists: the key lives in the shared agent
```

`use` env vars only last for the shell that ran them; `ssh-use` has a durable side
effect because it loads into the container-local agent on `$SSH_AUTH_SOCK`.

## GitHub Authentication (ghapp)

GitHub auth uses **runtime-minted, repo-scoped GitHub App tokens** (`ghapp`)
rather than static Personal Access Tokens. Every token is bound to a **single
repository**, carries only the permissions the operation needs, expires within
an hour, and is never written to disk — the App private key is read from
1Password (`op read`) at mint time.

The old static PAT profiles have been removed. Use `gh-app`, `ghapp`, or
`ght` for repository-scoped GitHub authentication.

The App (`igou-dev`) is installed on multiple accounts; the owner half of
`OWNER/REPO` picks the installation, so `david-igou/*`, `igou-io/*`, and
`aiops-ansible-software-factory-demojam/*` work from one config
(`~/.config/ghapp/config.yaml`, seeded by `post-create.sh`).

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
| `make e2e` | Full end-to-end: rebuild devcontainer + run all tests |

## Agent CLIs and credential profiles

Claude Code, Codex, Cursor agent, and OpenCode run directly from their installed
binaries. This repo no longer ships agent launch wrappers or the OpenCode
1Password masking shim. OpenCode now launches its installed binary directly,
with the current shell's credentials and filesystem access.

`use` and `unuse` still activate credential profiles for local shells. For
in-cluster consumers, `dotfiles/.bashrc.d/05-agent-profile.sh` activates an
ExternalSecret-rendered env catalog using `AGENT_PROFILE` and
`AGENT_PROFILE_ENVDIR` (default `/etc/agent/envs`).

`envs/read-only.env` bundles the OCP, rk8s, RouterOS, and TrueNAS readers.
The `ocp-alerts`, `ocp-logs`, `routeros-ro`, and `truenas-ro` infrastructure
helpers remain available after activating the appropriate profile.

## SSH Keys from 1Password

There is no host SSH agent forwarding and no private key on disk (see
[ADR-0004](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Environment%20and%20Credential%20Decisions.md)). `post-start.sh` starts an
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
Podman, host Docker socket access, or `/dev` access for `make run`, Hermes, or
CI without testing that exact runtime.

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

## OpenShift Dev Spaces

The published image can also be opened as an [OpenShift Dev
Spaces](https://devspaces.apps.ocp.igou.systems) workspace on the ocp
cluster — a browser IDE with no local docker at all:

```
https://devspaces.apps.ocp.igou.systems/#https://github.com/igou-io/igou-devenv
```

[`devfile.yaml`](devfile.yaml) defines the workspace: the container is the
published image, Dev Spaces injects its own che-code editor (the baked
code-server is unused), and
[`.devcontainer/devspaces-bootstrap.sh`](.devcontainer/devspaces-bootstrap.sh)
replaces the devcontainer lifecycle hooks (dotfiles, ghapp config, ssh-agent).

What carries over, and how:

- **1Password**: `OP_CONNECT_HOST`/`OP_CONNECT_TOKEN` are auto-mounted into
  the workspace from a per-user secret managed in igou-openshift
  (`components/devspaces/chart/devspaces-users`), so `op read`/`op inject` —
  and everything layered on them: `use`/`unuse`, `ssh-use`, ghapp token
  minting — work with no host mounts (ADR-0003 Connect mode).
- **Cluster access**: Dev Spaces logs `oc` in as your OpenShift user
  automatically; no kubeconfig mount.
- **Repos**: cloned under `/projects` on your per-user PVC (the plain-HTTPS
  ghapp credential helper is baked into the image), not the host `/workspace`.
- **Nested podman**: partial. Workspaces run under the `container-build` SCC;
  with the env recipe in igou-devenv#209, image pulls, COPY-only builds, and
  push work — but `RUN` steps and `podman run` are blocked by the SCC (masked
  `/proc`, no DAC_OVERRIDE, setgroups-deny). There is **no** `--privileged`,
  host network, Docker socket, or `/dev` passthrough: libvirt/qemu-kvm
  molecule scenarios do not run here. Agent CLI auth state
  starts fresh (no host bind mounts) and then persists on the PVC. See
  [igou-docs/devenv/Devenv Runtime Models and Capability Validation.md](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Runtime%20Models%20and%20Capability%20Validation.md).

## Dependency Management (Renovate)

All tool versions are pinned and managed by [Renovate](https://docs.renovatebot.com/):

- **Dockerfile base image** — the selected stable Fedora tag floats; Renovate uses released Fedora versions from endoflife.date and proposes OS upgrades for review
- **Ansible Core** — `main` tracks stable releases; `devel` also accepts published alpha/beta/RC versions. Core has a separate manual-merge group without the shared release-age delay or weekly schedule
- **Mise-managed CLI tools** — pinned in `mise.toml`, per-asset checksums in `mise.lock`. Renovate's native `mise` manager handles aqua/npm tools; a custom regex handles all annotated `http:` tables. Both use the `mise-managed cli tools` group, whose preparation workflow regenerates the lock before enabling auto-merge.
- **OpenShift CLI** — the shared `openshift-mirror` datasource reads `Version:` and `Created:` from Red Hat's release metadata. Its release timestamp preserves the 10-day age gate.
- **aqua-registry pin** — the registry URL contains an immutable release commit SHA, with its tag alongside it. Renovate's `github-tags` datasource updates both together in a separate group with automerge disabled; `tests/test-mise.sh` checks for per-tool verification downgrades.
- **Mise itself** + Claude Code + Cursor agent + opencode — pinned in `.devcontainer/Dockerfile` ARG blocks with `# renovate:` comments and the `github-releases` datasource (custom regex manager). Verified at build time: mise and Claude Code via pinned-fingerprint GPG signatures, Cursor agent and opencode via SHA256.
- **Python packages** — pinned in `.devcontainer/requirements.txt`, updated by `pip_requirements` manager.

Trust anchors (mise itself, aqua-registry pin) are routed into their own
Renovate groups in `renovate.json` so they get reviewed separately from
routine tool bumps.

To test Renovate config locally:
```bash
make renovate-validate                     # validate config syntax
GITHUB_TOKEN="$(ghapp token --repo igou-io/igou-devenv --permission contents=read)" make renovate-dry-run
```

The `Renovate coverage` PR check exercises Renovate's real extraction and
replacement engine against every HTTP tool and the registry tag/SHA, verifies
the lockfile handoff rules, and tests OpenShift feed timestamps offline. It
reads the candidate `renovate-base.json` directly, so it tests shared-preset
changes before they reach `main`. Local dry-runs resolve the published preset.

Preparation commits use `dependency-preparation@igou-devenv.invalid`, which
`gitIgnoredAuthors` recognizes so Renovate can refresh generated lock/checksum
branches. The former GitHub Actions author remains recognized for existing
prepared PRs. Human edits still freeze a branch, and GitHub's required CI and
review rules still apply to auto-merge.

### Weekly release

A Monday pipeline cuts a dated release of the devcontainer, with all schedules
using the `America/New_York` time zone so they track Eastern daylight-saving
changes:

- `build.yaml` (06:00 Eastern) builds, tests, and publishes `:latest`.
- `release-prepare.yaml` (06:30 Eastern) regenerates `mise.lock` on the week's
  Renovate mise PR and enables GitHub auto-merge (it can't merge itself — the
  hosted app can't regenerate the lock); GitHub merges it once `build` passes.
  It also runs when Renovate opens or updates the same-repository mise group
  PR, so time-sensitive tools do not wait for the weekly schedule.
- `release.yaml` (08:00 Eastern) promotes the tested `:latest` digest to
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

GitHub Actions builds the Dockerfile with Docker Buildx on pushes and PRs to
`main` and `devel`, then runs the existing test suite inside the image.
Successful branch builds publish `:latest` from `main` and `:devel` from
`devel`; PRs do not publish. Weekly scheduled builds and CalVer releases use
`main` and `:latest`. Devel builds run on pushes or manual workflow dispatch.
Only main images update the repository dependency graph.

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

Hermes dependencies must be added to the image Hermes actually enters. Verify
the installed dependency in that runtime.

### 1Password Integration

The 1Password CLI authenticates via **1Password Connect**
(`OP_CONNECT_HOST` + `OP_CONNECT_TOKEN`), sourced from
`~/.config/op/connect-host` and `~/.config/op/connect-token`
(bind-mounted read-only from the host). It falls back to
`OP_SERVICE_ACCOUNT_TOKEN` (`~/.config/op/service-account-token`) when the
Connect creds are absent. Connect reads hit the self-hosted server, so
they aren't subject to the 1password.com service-account API rate limit.
The export happens before `.bashrc`'s interactive-shell check, so
non-interactive shells (agent tool calls, scripts) get it too — `ghapp`
reads the GitHub App key from 1Password at mint time, so without it
`gh-app` and git's credential helper fail with "No accounts configured for
use with 1Password CLI".

Use the `use` function for environment switching — see
[ADR-0001](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Environment%20and%20Credential%20Decisions.md) and
[ADR-0003](https://github.com/igou-io/igou-docs/blob/main/devenv/Devenv%20Environment%20and%20Credential%20Decisions.md).

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

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.config/op ~/.config/opencode ~/.config/openshell ~/.claude
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
