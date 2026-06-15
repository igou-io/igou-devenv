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
.github/workflows/build.yaml         # CI: builds full devcontainer on push/PR via devcontainers/ci
.github/workflows/mise-lockfile-check.yaml  # CI: fails PRs whose mise.lock is stale vs mise.toml
.github/workflows/release-prepare.yaml  # CI: Mon 06:30 — regenerate mise.lock + auto-merge the mise PR
.github/workflows/release.yaml          # CI: Mon 08:00 — weekly CalVer image + git tag + GitHub Release
```

**Tool installation layers:**

| Layer | What | Where to add |
|---|---|---|
| Dockerfile (apt) | python3, podman, buildah, skopeo, jq, 1Password CLI, qemu-kvm, qemu-img, genisoimage, edk2-ovmf (virtualization), etc. | `.devcontainer/Dockerfile` |
| Mise (mise.toml + mise.lock) | kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, rclone, direnv, age, node, oc, virtctl, kube-burner, kube-burner-ocp, code-server | `mise.toml` (versions), `mise.lock` (per-asset SHA256) |
| Dockerfile (binary downloads) | mise itself (GPG-signed checksums), Cursor agent, opencode, Claude Code | `.devcontainer/Dockerfile` (ARG + RUN) |
| pip (onCreateCommand) | Ansible ecosystem, yq, mkdocs-material | `.devcontainer/requirements.txt` |

**Lifecycle hooks** (execution order):

| Hook | Runs on | Script | Purpose |
|---|---|---|---|
| `initializeCommand` | Host | `init.sh` | Creates mount directories before container build |
| `onCreateCommand` | Container | (inline) | `pip install` — runs after Features install Python |
| `postCreateCommand` | Container | `post-create.sh` | Shell config, workspace file |
| `postStartCommand` | Container | `post-start.sh` | SSH agent check, Docker socket perms, libvirt/dbus daemons, code-server (always-on), Claude config restore (every start) |

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
make release            # Cut a release now: promote tested :latest -> CalVer tag + Release
make release-dry-run    # Dry-run the release (resolve + plan only; no side effects)
make release-prepare    # On demand: regenerate mise.lock on the open Renovate mise PR and merge it
make release VERSION=2026.06.18-2 FORCE=true  # override the tag / bypass skip guards
claude-run              # Launch Claude in the container (see bin/claude-run)
claude-run -e ocp-rosa  # Launch with resolved cluster credentials
claude-run --shell      # Drop to bash inside the container
cursor-run              # Launch Cursor agent in the container (see bin/cursor-run)
cursor-run -e ocp-rosa  # Launch with resolved cluster credentials
cursor-run --shell      # Drop to bash inside the container
```

### Bumping a CLI tool version

Tools managed by mise (see Architecture table) are pinned in `mise.toml`
with per-asset checksums in `mise.lock`. Renovate bumps the *version* in
`mise.toml` but cannot regenerate `mise.lock` — the hosted Mend app cannot run
postUpgradeTasks — so its raw PRs are stale and fail the `mise-lockfile-check`
CI guard. `release-prepare.yaml` handles this automatically (Mondays, or on
demand via `make release-prepare`): it regenerates the lock on the open mise PR
and enables auto-merge. You only step in if a bump genuinely breaks the build
(release-prepare files an issue) — then fix it by hand on the
`renovate/mise-managed-cli-tools` branch (`make mise-lock`, commit, push). (The
mise binary itself is verified against mise's GPG-signed checksums, so a
version-only `MISE_VERSION` bump needs no follow-up.) To bump a tool manually:

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

### Weekly release (CalVer)

Every Monday two scheduled workflows run:

1. `release-prepare.yaml` (06:30 UTC) regenerates `mise.lock` on the open
   Renovate mise PR (`bin/release-prepare-mise`) and **enables GitHub
   auto-merge** — using `RELEASE_PAT`; GitHub squash-merges the PR once the
   required `build` check passes (the job no longer blocks waiting). The mise
   group is `automerge:false` in `renovate.json` so this job is its sole merger.
   If the lock can't be regenerated (e.g. a version that won't resolve) it files
   an issue and leaves the PR open; a bump that locks but then fails the build
   just leaves the PR open (red, auto-merge pending) — the release still ships
   the rest.
2. `release.yaml` (08:00 UTC) **promotes** the already-tested
   `ghcr.io/igou-io/igou-devenv:latest` image (built + tested by `build.yaml` on
   every push to `main`) to the immutable dated tag `:YYYY.MM.DD` **by digest —
   no rebuild** — so the released image is byte-identical to what CI tested. It
   then pushes tag `vYYYY.MM.DD` and creates a GitHub Release (auto notes +
   SBOM). `:latest` is owned by `build.yaml`; release no longer publishes
   `:latest`. Skips weeks with no changes; idempotent.

Manual fallback: if `release-prepare` files an issue, regenerate the lock by
hand — `make mise-lock` on the `renovate/mise-managed-cli-tools` branch, then
push; it merges and rides the next weekly release.

Manual / test release: use the `make release*` targets (`make release`,
`make release-dry-run`, `make release-prepare`; they wrap the dispatches and need
a gh token with Actions: write), or drive `release.yaml` directly — it is
`workflow_dispatch`-able (Actions tab or `gh workflow run release.yaml`):
- `-f dry_run=true` — resolve + plan only, no promote/tag/release (safe, repeatable).
- `-f version=0.0.0-test -f force=true` — cut a throwaway release on demand
  (unique `version` avoids clashing with the real weekly CalVer tags; `force`
  bypasses the "tag exists / main not advanced" skip guards). Delete the test
  tag/release/image afterward.

Requires the `RELEASE_PAT` repo secret (Contents + Pull-requests: read/write).

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
- **Trust anchors**: The mise binary is bootstrapped by verifying its release tarball against mise's GPG-signed checksums (`SHASUMS256.asc`), anchored on the pinned release-key fingerprint `24853EC9F655CE80B48E6C3A8B81C9D17413A06D` (uid "mise releases <release@mise.jdx.dev>", fetched from `https://mise.jdx.dev/gpg-key.pub` but rejected unless fingerprint + VALIDSIG match) — that pinned fingerprint is the chicken-and-egg trust anchor for tool installs, and Renovate bumps `MISE_VERSION` only (no per-version SHA to maintain). Mise then verifies the 21 managed tools via aqua-registry's pinned cosign/SLSA/GPG/SHA256 config. Where aqua-registry's mise install path doesn't run the upstream signature step (helm, terraform, oc), `aqua-registry/<tool>-postinstall.sh` re-runs the GPG verification against a pinned-fingerprint key. The aqua-registry itself is pinned to a specific git SHA, Renovate-bumped, and the bump is gated by `tests/test-mise.sh` which asserts no verification method silently downgraded.
- **QEMU available in-container**: `qemu-kvm`, `qemu-img`, `genisoimage`, `edk2-ovmf`, `libvirt-daemon`, `libvirt-client`, and `python3-libvirt` are baked into the image so the `qemu` provisioner from [`ansible-collection-molecule_provisioners`](https://github.com/david-igou/ansible-collection-molecule_provisioners) can launch both process-driver and libvirt-driver guests. Ansible Galaxy collections (e.g. `community.libvirt`) are not baked into the image — install per-project via `ansible-galaxy collection install` at runtime if needed. `/dev/kvm` is accessible via the existing `/dev` bind-mount + `--privileged` runArgs. `virtqemud` is started by `post-start.sh` on every container start (`auth_unix = "none"` because the container has no systemd/D-Bus/polkit; access control falls back to socket file permissions). Host-side prep (kernel module load, `/dev/kvm` permissions) is tracked in [`ansible-collection-devhost#33`](https://github.com/david-igou/ansible-collection-devhost/issues/33).
- **code-server (browser IDE, always-on)**: Installed via mise's `http:` backend (`mise.toml` → `http:code-server`). Upstream ships no checksums/signatures/SLSA provenance and is not in aqua-registry, so the blake3 TOFU pin in `mise.lock` is the verification floor (same as virtctl/kube-burner; audited as `blake3` in `tests/mise-expected-verification.toml`). Unlike other http: tools it's a wrapper+lib tree, so `bin_path = "bin"` + `strip_components = 1` point mise at the launcher. `post-start.sh` starts it always-on, bound to `0.0.0.0:8080` (reachable on the host via `--network=host`), with mandatory `auth: password`. Because the container is `--privileged` with `/dev` bind-mounted, the port grants full host access — auth must never be disabled; prefer SSH/Tailscale to reach it. Config ships in `dotfiles/code-server-config.yaml` (no secret), copied by `post-create.sh` **only if absent**; the password is generated on first start (override with the `PASSWORD` env var). `~/.config/code-server` and `~/.local/share/code-server` are bind-mounted (sources created by `init.sh`), so the config/password, extensions, and settings persist across rebuilds — which is why the seed copy is conditional (it must not clobber the persisted config). Extensions come from Open VSX, not the MS marketplace. Added to the shared `mise.toml` so it lands in all three Dockerfiles, but only started in the primary `.devcontainer/` (the `builds/podman-*` variants are being sunset).
