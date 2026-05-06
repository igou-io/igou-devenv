# Add `opencode` to the devcontainer image

**Date:** 2026-05-06
**Status:** Approved
**Repo:** `igou-devenv`

## Goal

Install the [`opencode`](https://opencode.ai) CLI inside the `igou-devenv` devcontainer image so it is available alongside `claude` and `cursor-agent` when the user is working inside the VS Code / Cursor devcontainer.

## Background

Today the devcontainer (`.devcontainer/Dockerfile`) installs two AI assistant CLIs at the bottom of the image:

- `claude-code` — `curl -fsSL https://claude.ai/install.sh | bash`
- `cursor-agent` — `curl -fsSL https://cursor.com/install | bash` (binary lands at `~/.local/bin/agent`)

A separate, fully-baked `opencode` container already exists at `igou-containers/apps/opencode` (consumed via `bin/opencode-run`). It installs opencode as user 1000 with `curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path`, which drops the binary at `~/.opencode/bin/opencode`.

The `devcontainer.json` in this repo already bind-mounts `~/.config/opencode` into the devcontainer (line 40), so the slot is reserved — only the binary itself is missing from the image used by VS Code / Cursor.

## Design

### Dockerfile change (`.devcontainer/Dockerfile`)

Append a third install block at the end of the file, immediately after the existing `cursor-agent` block, mirroring its shape:

```dockerfile
# opencode CLI
USER igou
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    ln -s /home/igou/.opencode/bin/opencode /home/igou/.local/bin/opencode && \
    ~/.local/bin/opencode --version
USER root
```

Three properties of this block:

1. **Runs as `igou` (UID 1000).** Matches the working pattern in `igou-containers/apps/opencode/Containerfile`. The installer creates files under `~/.opencode/`, which must be owned by the eventual runtime user.
2. **`--no-modify-path` flag.** The default installer edits the user's shell rc files to prepend `~/.opencode/bin` to PATH. The devcontainer's `dotfiles/.bashrc` is curated and re-copied by `post-create.sh`, so installer-side rc edits would be silently overwritten. This flag suppresses them.
3. **Symlink to `~/.local/bin/opencode`.** `~/.local/bin` is already on `PATH` via line 13 of `dotfiles/.bashrc` (`export PATH=$PATH:/home/igou/.local/bin:/home/igou/bin`). A single symlink exposes opencode without touching the shared bashrc — same end-state as cursor's installer (which lands its binary in `~/.local/bin/agent`). Verifying via `~/.local/bin/opencode --version` proves the symlink is correct *and* that the binary executes.

### Test coverage (`tests/test-tools.sh`)

Add one entry to the `TOOLS` associative array (sorted alphabetically into its position):

```bash
[opencode]="opencode --version"
```

Rationale: `claude` is already tested (line 24) and plays the same role as `opencode`. Cursor's `agent` is intentionally omitted from tests today; opencode follows the `claude` precedent for parity.

### What is *not* changing

| Area | Reason |
|---|---|
| `devcontainer.json` | `~/.config/opencode` already bind-mounted (line 40); no other config needed. |
| `dotfiles/.bashrc` | `~/.local/bin` already on PATH; symlink approach avoids any edit. |
| `requirements.txt` | opencode is not a Python package. |
| `renovate.json` | Following the established precedent for `claude` and `cursor-agent` — both use rolling install scripts with no version pin. opencode does the same. |
| `bin/opencode-run` | Unrelated; that script targets the standalone `ghcr.io/igou-io/opencode` image and is independent of the devcontainer install. |
| `Makefile` / `post-create.sh` / `post-start.sh` | No lifecycle hook changes required — install is a build-time concern only. |
| `CLAUDE.md` / docs | The "Available Tools" line in the global `CLAUDE.md` describes the `claude-run` runtime container, not this devcontainer image. No doc update needed. |

## Verification

Per the user's instruction for this change (env is in use), local `make rebuild && make test` is **skipped**. Validation strategy:

1. Push the branch directly to `main`.
2. Watch the GitHub Actions `build.yaml` workflow with `gh run watch`.
3. If CI fails, surface the failure and remediate.
4. Once CI passes, the next devcontainer rebuild on the user's machine (whenever they next launch it) will pick up the new image layer.

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `opencode.ai/install` script changes its behavior or output path | Low | The `~/.local/bin/opencode --version` step at the end of the `RUN` will fail loudly during the image build, breaking CI. |
| Installer requires network egress to a domain blocked by build environment | Very Low | `claude.ai/install.sh` and `cursor.com/install` already work from the same build environment; opencode.ai is an external CDN with the same access pattern. |
| Symlink dangles if installer's binary path changes upstream | Low | Same `--version` check catches a dangling symlink. |
| New layer adds image size | Low | Acceptable; the standalone opencode image already pays the same cost. |

## Out of scope

- Adding opencode to the **runtime** container launched by `claude-run` (that container is built from `igou-containers`, not this repo).
- Pinning opencode to a specific version via Renovate (would diverge from the `claude`/`cursor-agent` precedent).
- Pre-seeding opencode's auth tokens or model config.
