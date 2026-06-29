# AGENTS.md

This file is the single cross-agent source of truth for Codex, Claude Code,
Cursor agent, OpenCode, and other coding agents working in this repository.
`CLAUDE.md` is only a compatibility pointer to this file.

## Purpose

`igou-devenv` is a reproducible development environment for homelab
infrastructure work with OpenShift, Kubernetes, Ansible, Terraform, podman,
buildah, QEMU/libvirt, and related tooling.

This repo owns the local devcontainer definition, lifecycle scripts, local
launcher wrappers, and tests for that development environment. The actual
infrastructure project repos are expected to be cloned separately under
`/workspace/`. The local agent container images launched by the wrapper scripts
are built in `igou-containers`, not here.

## User Preferences

- Prefer declarative, Renovate-managed version pinning over ad hoc install
  logic.
- Preserve clean separation of concerns: base image plus overlays, standalone
  files instead of generated heredocs, repo-specific logic close to the repo
  that owns it.
- Design workspace handling so projects can be added or removed dynamically.
  Avoid tight coupling to the `igou-devenv` directory layout when functionality
  may later move to its own repo.
- Before changing release automation, mise management, QEMU/devcontainer
  behavior, or code-server behavior, check the matching design or plan in
  `docs/superpowers/{specs,plans}` when one exists.
- For Codex: use the `adding-a-mise-tool` skill when adding or changing
  mise-managed CLI tools in this repo.

## Execution Models

Do not assume all paths through this repo have the same runtime capabilities.
See [docs/execution-models.md](docs/execution-models.md) for the detailed
matrix.

| Model | Entry point | Capability summary |
|---|---|---|
| Local full devcontainer | Cursor Dev Containers or `make up` | Docker-launched, privileged, host networking, `/dev` bind mount, Docker socket, persistent host config mounts, nested Podman/buildah support. Intended for David's trusted local dev machine. Not a security sandbox for untrusted agent execution. |
| Lightweight published image path | `make run` | Runs `ghcr.io/igou-io/igou-devenv` directly for code-server against a selected directory. Does not imply the same persistence, lifecycle hooks, privileged mode, or nested-container capability as `make up`. |
| Local wrapper-launched agent containers | `bin/claude-run`, `bin/cursor-run`, `bin/opencode-run` | Convenience wrappers normally run from inside the local full devcontainer. They use rootless Podman to pull/run images built by `igou-containers`, resolve selected `envs/*.env` files through `op inject`, and pass plain environment variables to the agent container. |
| Hermes docker-terminal container | Hermes docker terminal setting | Hermes enters whatever image Hermes is configured to use in a rootless Podman environment. It is not assumed to be this repo's full devcontainer and not assumed to run the local wrapper scripts. |
| CI/build environment | GitHub Actions/devcontainers CI | Builds and tests the devcontainer image. It should hard-fail on missing packages and broken commands, but should not hard-fail on namespace or bubblewrap runtime capabilities unless CI explicitly provides them. |

Hard execution-model rules:

- Do not treat `claude-run`, `cursor-run`, or `opencode-run` as Hermes paths.
- Do not assume Hermes can run `claude-run`, `cursor-run`, or `opencode-run`.
- Do not assume Hermes has privileged mode, host networking, the host Docker
  socket, `/dev` bind mounts, nested Podman, or wrapper-launched agent
  containers.
- The outer container is the primary isolation boundary for Hermes.
- When adding dependencies for Hermes, patch the image Hermes actually enters, not merely local wrapper-launched agent images.
- Runtime capabilities such as user namespaces, mount namespaces, seccomp,
  Landlock, and bubblewrap must be tested inside the actual container where the
  agent runs.
- Do not claim a sandbox exists unless the relevant tool supports one and the runtime smoke test passes.
- OpenCode permissions are UX guardrails, not OS isolation.

## Common Commands

```bash
make build              # Build the devcontainer image (cached)
make up                 # Build and start the full local devcontainer
make up-release         # Start full devcontainer from a published image tag
make run                # Lightweight code-server path from published image
make rebuild            # Full rebuild from scratch (no cache)
make down               # Stop and remove the devcontainer
make shell              # Open bash shell in running devcontainer
make exec CMD="..."     # Run a one-off command in the devcontainer
make test               # Run all normal tests (alias for test-all)
make test-tools         # Hard package/command/Python/user-config checks
make test-podman        # Test nested Podman pull, run, and build
make test-env           # Test environment switching functions
make test-sandbox-primitives  # Diagnostic namespace/bubblewrap smoke test
make renovate-validate  # Validate renovate.json config
GITHUB_TOKEN=... make renovate-dry-run
make e2e                # Full end-to-end: rebuild devcontainer + all tests
make release            # Promote tested :latest to a CalVer tag + release
make release-dry-run    # Resolve + plan release only
make release-prepare    # Regenerate mise.lock on the open Renovate mise PR
```

Pre-push requirement: do not push changes to the remote unless `make rebuild`
followed by `make test` passes locally, unless the user explicitly asks to push
anyway.

## Architecture

```text
.devcontainer/
├── Dockerfile           # dnf packages, CLI binary downloads, mise bootstrap
├── containers-storage.conf
├── devcontainer.json    # full local devcontainer config and mounts
├── init.sh              # host-side initializeCommand
├── post-create.sh       # shell config, workspace file
├── post-start.sh        # SSH/socket checks, libvirt/dbus, code-server sync/start
├── code-server-sync.sh  # applies devcontainer.json VS Code customizations to code-server
└── requirements.txt     # pinned Python packages
dotfiles/                # .bashrc, tmux, code-server config, workspace file
bin/                     # local helper scripts and wrapper launchers
envs/                    # 1Password env files with op:// references only
tests/                   # devcontainer and helper-script tests
docs/                    # runtime model docs and design records
mise.toml / mise.lock    # mise-managed tool versions and per-asset checksums
renovate.json            # Renovate config
```

Lifecycle hooks:

| Hook | Runs on | Script | Purpose |
|---|---|---|---|
| `initializeCommand` | Host | `.devcontainer/init.sh` | Create mount directories before build/start |
| `onCreateCommand` | Container | inline in `devcontainer.json` | Install Python requirements |
| `postCreateCommand` | Container | `.devcontainer/post-create.sh` | Configure shell, tmux, workspace, default code-server config |
| `postStartCommand` | Container | `.devcontainer/post-start.sh` | Check SSH/socket state, start libvirt/dbus/code-server, sync code-server settings |

## Where To Add Dependencies

| Dependency type | Add it here | Notes |
|---|---|---|
| OS packages required in the main devcontainer image | `.devcontainer/Dockerfile` dnf block | Use repo packages where available. Hard-test command availability in `tests/test-tools.sh` when the package is required. |
| Mise-managed CLI tools | `mise.toml` and `mise.lock` | Run `make mise-lock`; commit both files. Use the `adding-a-mise-tool` skill for Codex. |
| Python packages | `.devcontainer/requirements.txt` | Pin versions for Renovate's native manager. |
| Standalone binaries without a dependency ecosystem | Dedicated `.devcontainer/Dockerfile` ARG/RUN block | Keep rare. Use Renovate annotations and cryptographic or checksum verification. |
| Local helper scripts | `bin/` | These are symlinked into `~/bin` by `post-create.sh`. |
| Runtime config files | `dotfiles/` or the owning repo | Avoid large heredocs or generated multi-line files embedded in shell scripts or Dockerfiles. |
| Local wrapper-launched agent image dependencies | `igou-containers` | `bin/*-run` pulls those images; this repo does not build them. |
| Hermes dependencies | The image Hermes actually enters | Do not patch only local wrappers or their images and claim Hermes has the dependency. |

Where not to add dependencies:

- Do not add Hermes-only assumptions to `bin/claude-run`, `bin/cursor-run`, or
  `bin/opencode-run`; they are local full-devcontainer wrappers.
- Do not put local wrapper-launched agent image packages in this repo unless
  the package is also required by the main devcontainer image.
- Do not use inline generated file definitions when a standalone file can be
  copied or installed.

## Sandbox And Capability Rules

Package availability and runtime capability are separate claims.

- `tests/test-tools.sh` is the hard package/command availability test.
- `tests/test-sandbox-primitives.sh` is a diagnostic runtime smoke test for
  user namespaces and bubblewrap. It is non-fatal by default for restricted CI
  or non-Hermes environments; set `REQUIRE_SANDBOX_PRIMITIVES=true` when the
  runtime must provide those primitives.
- A passing package check does not prove bubblewrap, user namespaces, mount
  namespaces, seccomp, or Landlock works in a given runtime.
- A sandbox claim must identify the tool and runtime tested.

Agent-specific guidance:

- Codex: Linux sandboxing expects bubblewrap or a compatible helper. The
  package must exist in the image where Codex runs, and runtime smoke tests must
  pass before claiming the sandbox works.
- Claude Code: Linux sandboxing expects bubblewrap and socat. Treat fail-closed
  behavior as true only when configured and verified in that runtime.
- Cursor agent: Linux sandboxing is Landlock/seccomp based when supported. Test
  inside the runtime before claiming support.
- OpenCode: permissions are UX guardrails, not native OS isolation. Isolate it
  with the outer container or VM.
- Pi-style agents and sandbox extensions commonly need bubblewrap, socat, and
  ripgrep. Test inside the runtime where they execute.

Do not say "agent containers have bubblewrap + seccomp sandbox" generically.
Say "tool-specific native sandboxing may be available; verified by tests" only
after the relevant test has actually passed.

## Key Design Decisions

- The full devcontainer is launched by Docker on the host, not Podman. Podman
  is used inside the full devcontainer for nested container workflows.
- The full devcontainer uses Docker `--privileged`, host networking, a host
  `/dev` bind mount, `/dev/fuse`, `/dev/net/tun`, and a Docker socket mount.
  This is acceptable for David's trusted single-user homelab workstation, but
  it is not a sandbox for untrusted agent execution.
- Repos are expected to be pre-cloned on the host at `~/workspace` and
  bind-mounted into the container. The devcontainer does not clone repos.
- Read-only mounts are used for `~/.ssh`, `~/.gitconfig`, and `~/.config/op`.
  Kube and tool state mounts are persistent because this is a development
  environment.
- `use <env>` resolves 1Password references with `op inject` and exports them
  in the current shell; `unuse <env>` removes them. Environment files in `envs/`
  contain only `op://` references.
- Python packages are installed directly with pip into the disposable container
  rather than isolated with pipx.
- The mise binary is bootstrapped by verifying release checksums with a pinned
  GPG fingerprint. Mise-managed tools are pinned in `mise.lock`, and
  `tests/test-mise.sh` audits the expected verification method.
- `codex`, Claude Code, Cursor agent, and OpenCode installed in the main
  devcontainer are pinned and verified in the Dockerfile. Persistent agent
  state is mounted from host directories, not baked into the image.
- code-server is installed via mise, started by `post-start.sh`, and bound to
  `0.0.0.0:8080` with mandatory password auth. Because the full devcontainer is
  privileged with `/dev` mounted, anyone reaching code-server gets powerful host
  access. Prefer SSH/Tailscale paths and never disable auth.
- `.devcontainer/code-server-sync.sh` bridges `devcontainer.json`
  customizations into code-server because code-server does not read
  `devcontainer.json` directly.
- QEMU/libvirt tooling is available in the full devcontainer for molecule
  provisioner work. `/dev/kvm` access depends on the host and the privileged
  `/dev` bind mount.
- Terminal and shell history persistence use tmux and
  `~/.local/share/igou-devenv`, which is bind-mounted by the full devcontainer.

## Mise Tool Bumps

Tools managed by mise are pinned in `mise.toml` with per-asset checksums in
`mise.lock`. Renovate bumps `mise.toml`; the lockfile must be regenerated
separately.

```bash
# 1. Edit mise.toml
# 2. Regenerate the lockfile
make mise-lock
# 3. Validate
make test
# 4. Commit mise.toml and mise.lock together
```

If `tests/test-mise.sh` reports a verification downgrade, update
`tests/mise-expected-verification.toml` only after confirming the upstream
change was deliberate.

## Release Notes

Weekly release automation has two scheduled workflows:

- `release-prepare.yaml` regenerates `mise.lock` on the open Renovate mise PR
  and enables GitHub auto-merge with `RELEASE_PAT`.
- `release.yaml` promotes the already-tested
  `ghcr.io/igou-io/igou-devenv:latest` image by digest to an immutable
  `:YYYY.MM.DD` tag, creates a `vYYYY.MM.DD` git tag, and publishes a GitHub
  Release. It does not rebuild the image.

Manual release targets are `make release`, `make release-dry-run`, and
`make release-prepare`.

## Linting

```bash
shellcheck .devcontainer/post-create.sh .devcontainer/post-start.sh .devcontainer/init.sh dotfiles/.bashrc tests/*.sh bin/claude-run bin/cursor-run bin/opencode-run
```
