# ADR-0003: Hardened Claude Container Design

## Status

Accepted

## Date

2026-03-28

## Context

Claude Code runs as an AI agent with shell access — it can install packages, modify dotfiles, and make arbitrary changes to the host environment. When pointed at infrastructure repos (Ansible playbooks, Kubernetes manifests, Terraform configs), the blast radius of a mistake is significant. The main devcontainer is a general-purpose environment with `sudo`, package managers, and broad filesystem access — not appropriate for unsupervised agent work.

### Requirements

- Run Claude Code sessions in a container with minimal privileges
- Prevent the agent from installing packages, modifying system files, or escaping the workspace
- Integrate with the existing `use()` environment switching ([ADR-0001](0001-environment-switching-with-1password.md)) for cluster credentials
- Bake infrastructure tools (kubectl, helm, ansible, etc.) into the image so the agent has everything it needs without needing to install anything
- Persist session history and credentials across container restarts
- Support passing credentials through environment variables (e.g., `ANTHROPIC_API_KEY`) for headless/CI usage without requiring host `~/.claude/` state
- Work from inside the devcontainer (nested rootless podman)

## Decision

Build a UBI10-based rootless container launched via `claude-run`, with hardening applied at two complementary layers: **podman flags** (outer, hard enforcement) and **Claude Code sandbox settings** (inner, application-level).

### Image architecture

The Containerfile uses a three-stage build to produce a minimal image without package managers:

```
Stage 1: ubi-micro           # Minimal rootfs (~40 MB), no dnf/rpm
Stage 2: ubi (build)         # Full UBI for dnf --installroot, pip, curl
Stage 3: scratch             # COPY rootfs from build stage
```

The build stage installs everything into the ubi-micro rootfs via `dnf --installroot` and `chroot pip install`, then the final `FROM scratch` copies only the populated rootfs. The resulting image has no `dnf`, `rpm`, `pip`, or `ansible-galaxy` — the agent cannot install additional packages.

### Tool installation

All tools are baked into the image at build time:

| Layer | Tools | Update mechanism |
|---|---|---|
| dnf (system) | bash, git, python3, jq, make, nmap, curl, etc. | Base image update |
| Binary downloads | kubectl, helm, gh, argocd, kustomize, oc, virtctl, kubeconform, tkn, mc, rclone, kubernetes-mcp-server | Renovate (ARG version pins) |
| pip (chroot) | ansible, ansible-runner, ansible-lint, yq, kubernetes, jmespath, yamllint | Renovate (requirements.txt) |
| npm (build-time) | seccomp filter, apply-seccomp (via @anthropic-ai/sandbox-runtime) | Renovate (package.json) |
| dnf (CentOS 10-stream) | bubblewrap | Base image update |
| Claude Code | Native binary via install script | Image rebuild |

After pip install, package managers are removed:

```dockerfile
rm -f ${DNF_INSTALL_ROOT}/usr/bin/pip ${DNF_INSTALL_ROOT}/usr/bin/pip3 \
      ${DNF_INSTALL_ROOT}/usr/local/bin/pip ${DNF_INSTALL_ROOT}/usr/local/bin/pip3 \
      ${DNF_INSTALL_ROOT}/usr/bin/ansible-galaxy \
      ${DNF_INSTALL_ROOT}/usr/local/bin/ansible-galaxy
rm -rf ${DNF_INSTALL_ROOT}/usr/lib/python3.12/site-packages/pip
```

### Hardening layers

#### Layer 1: Podman flags (enforced by `claude-run`)

These are OS-level restrictions the agent cannot bypass:

```bash
# Security
--cap-drop=ALL                          # No Linux capabilities
--security-opt no-new-privileges:true   # No setuid/setgid escalation

# Filesystem
--tmpfs /tmp:rw,noexec,nosuid,size=256m # Writable /tmp but no execution
--tmpfs /run:rw,noexec,nosuid,size=64m  # Writable /run but no execution
chmod 555 ~/.local/bin                  # Read-only PATH directory (baked in image)

# Resources
--cpus=2                                # CPU limit
--pids-limit=512                        # Fork bomb protection
--timeout=7200                          # 2-hour max session
--memory=4g --memory-swap=4g            # Memory limit (conditional on cgroup delegation)

# Ulimits
--ulimit nofile=1024:2048
--ulimit nproc=512:512
--ulimit core=0                         # No core dumps

# Process management
--rm                                    # Ephemeral container
--replace                               # Clean up stale containers from Ctrl+C
--init                                  # PID 1 reaping (conditional on catatonit)
--userns=keep-id                        # UID mapping for rootless
```

Some flags are conditional because they depend on host capabilities:

- `--init` requires `catatonit` on the host (not available in all environments)
- `--memory` requires cgroup memory controller delegation (unavailable in nested rootless containers)

#### Layer 2: Claude Code sandbox settings (baked at `/etc/claude/settings.json`)

Application-level restrictions within Claude's own execution model:

```json
{
  "sandbox": {
    "enabled": true,
    "enableWeakerNestedSandbox": true,
    "failIfUnavailable": false,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "allowWrite": ["."],
      "denyWrite": ["~/.local/bin", "~/.bashrc", "~/.profile", "~/.bash_profile"]
    },
    "network": {
      "allowedDomains": [
        "api.anthropic.com", "claude.ai", "statsig.anthropic.com",
        "sentry.io", "github.com"
      ]
    }
  }
}
```

- `enableWeakerNestedSandbox`: Required because Claude's bubblewrap sandbox cannot use full isolation inside a container
- Filesystem deny-write rules complement the OS-level `chmod 555 ~/.local/bin`
- Network allowlist restricts outbound connections at the application level
- `seccomp.bpfPath` and `seccomp.applyPath` point to the baked sandbox binaries at `/usr/local/lib/claude-sandbox/`

#### Sandbox dependencies (bubblewrap + seccomp)

Claude Code's sandbox requires bubblewrap (`bwrap`) for filesystem isolation and a seccomp filter (`unix-block.bpf` + `apply-seccomp`) to block Unix domain sockets. These are baked into the image:

- **bubblewrap**: Not available in UBI10 repos. Installed from CentOS 10-stream BaseOS via `--repofrompath` (avoids persisting the repo or conflicting with UBI packages):
  ```dockerfile
  RUN dnf ${DNF_OPTS_ROOT} ${DNF_OPTS} --nogpgcheck \
      --repofrompath=centos-baseos,https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/ \
      --repo=centos-baseos \
      install bubblewrap
  ```
- **seccomp filter**: Extracted from the `@anthropic-ai/sandbox-runtime` npm package at build time. Version is pinned in `claude-container/package.json` and managed by Renovate's native npm manager:
  ```json
  { "dependencies": { "@anthropic-ai/sandbox-runtime": "0.0.43" } }
  ```
  The build stage installs `nodejs-npm`, runs `npm install`, and copies the architecture-specific `unix-block.bpf` and `apply-seccomp` into `/usr/local/lib/claude-sandbox/`. Node.js is not included in the final image.

#### Layer 3: Python environment lockdown (baked in image)

```dockerfile
ENV PYTHONNOUSERSITE=1     # Block --user site-packages
ENV PYTHONPATH="..."       # Explicit path to keep /usr/local packages visible
ENV PIP_NO_INPUT=1         # Prevent pip prompts (pip is removed, but defense in depth)
```

Note: On RHEL/UBI, `PYTHONNOUSERSITE=1` also removes `/usr/local/lib*/python3.12/site-packages` from `sys.path`. The explicit `PYTHONPATH` works around this so pip-installed packages (ansible, etc.) remain importable.

### Why not `--read-only`

The root filesystem is not mounted read-only because Claude Code requires writable paths at the home root level (`~/.claude.json`, `~/.local/state/claude/locks/`, `~/.cache/claude-cli-nodejs/`). A tmpfs overlay on `$HOME` would hide all baked files (settings, Claude binary). The combination of `--rm` (ephemeral), noexec tmpfs, no package managers, and read-only `~/.local/bin` provides equivalent protection without breaking Claude.

### Config merging via entrypoint

The image bakes MCP server config (`/etc/claude/claude.json`) and sandbox settings (`/etc/claude/settings.json`) into `/etc/claude/`. At runtime, `~/.claude/` is bind-mounted from the host with existing user config. The entrypoint merges baked config into user config at startup:

- **`~/.claude.json`**: Created from baked `/etc/claude/claude.json` (not mounted from host — see below). If the file already exists, baked `mcpServers` are merged in.
- **`~/.claude/settings.json`**: Baked sandbox settings are deep-merged (baked keys take precedence)

If no host config exists, the baked files are copied as-is. This ensures sandbox restrictions and MCP servers are always active regardless of what the host provides.

### Why `~/.claude.json` is not bind-mounted

`~/.claude.json` is deliberately not mounted from the host. Bind-mounting individual files tracks the inode, not the path. When Claude Code replaces the file via atomic write (token refresh, re-login, settings change), the bind mount goes stale — the container sees the old deleted inode (`Links: 0`) and nested podman fails with "No such file or directory."

Instead, `claude-run` snapshots `~/.claude.json` into the mounted `~/.claude/.claude-state.json`, and the entrypoint seeds `~/.claude.json` from this snapshot at startup. Baked MCP config is then merged in. This means container sessions inherit auth state from the host without a file bind mount, while sharing session history, credentials, and settings through the `~/.claude/` directory mount (which is immune to this problem since directory mounts track the directory, not individual file inodes).

### Claude home directory

`CLAUDE_HOME` controls which host directory is mounted as `~/.claude` inside the container. It defaults to `~/.claude` (shared with the host), but is configurable for session isolation if needed:

```bash
CLAUDE_HOME="$HOME/.claude"
RUN_ARGS+=(-v "$CLAUDE_HOME:/home/igou/.claude:Z")
```

### Path-preserving workspace mount

Claude Code stores project memory, settings, and session history keyed by the absolute workspace path. If the workspace is mounted at a different path inside the container, Claude treats it as a different project and loses context.

`claude-run` mounts `$PWD` at the **same absolute path** inside the container:

```bash
RUN_ARGS+=(-v "$PWD:$PWD:Z" -w "$PWD")
```

When run from `/workspace/igou-ansible` inside the devcontainer, the Claude container also sees `/workspace/igou-ansible` — project memory, CLAUDE.md resolution, and `--resume` all work consistently across devcontainer and Claude container sessions.

### Environment integration

`claude-run` reuses the same `op inject` pattern from [ADR-0001](0001-environment-switching-with-1password.md) to resolve secrets and inject them as environment variables. This is the single mechanism for all credential types — cluster credentials, API keys, and Claude authentication tokens all flow through the same `-e` flag:

```bash
claude-run -e ocp-rosa              # Resolve cluster credentials
claude-run -e ocp-hub -e ansible    # Stack environments
claude-run -e claude-api            # Inject ANTHROPIC_API_KEY for headless/CI usage
claude-run -- --resume              # Pass flags through to claude
claude-run --shell                  # Drop to bash for debugging
claude-run --dry-run -e aws         # Preview the podman command
```

Example env files for credential passthrough:

```bash
# envs/claude-api.env — API key for headless sessions (no OAuth needed)
ANTHROPIC_API_KEY=op://Homelab/claude/api-key

# envs/ocp-rosa.env — cluster credentials (same pattern)
KUBECONFIG_DATA=op://awx/ocp-rosa/kubeconfig
```

This means the container can run without any host `~/.claude/` state — an env file with `ANTHROPIC_API_KEY` is sufficient for headless or CI workflows where OAuth credential seeding is impractical.

Container names are derived from active environments (`claude-session`, `claude-ocp-rosa`, `claude-ocp-rosa-ansible`) with `--replace` to handle stale containers.

### File layout

```
claude-container/
├── Containerfile        # Three-stage UBI10 build
├── requirements.txt     # Python packages (Renovate-managed)
├── package.json         # npm build-time deps — seccomp filter (Renovate-managed)
├── entrypoint.sh        # Git config, config merging, GitHub auth
├── claude.json          # Baked MCP server config (→ /etc/claude/)
├── settings.json        # Baked sandbox settings (→ /etc/claude/)
├── test.sh              # Tool verification (~12 assertions)
├── test-hardened.sh     # Hardened environment integration tests (~38 assertions)
└── test-claude-run.sh   # Launch script unit tests (~37 assertions)
bin/
└── claude-run           # Launch script with hardening flags
```

## Consequences

### Benefits

- **Agent cannot install packages**: No pip, dnf, rpm, or ansible-galaxy in the image
- **Agent cannot modify PATH**: `~/.local/bin` is `chmod 555`
- **Agent cannot execute from /tmp**: noexec tmpfs prevents downloaded binaries from running
- **Agent cannot escalate privileges**: `--cap-drop=ALL` + `no-new-privileges`
- **Resource-bounded**: CPU, memory, PID, and session time limits prevent runaway processes
- **Sessions persist**: History, credentials, and session state survive container restarts via `~/.claude/` mount
- **Config always enforced**: Entrypoint merges baked sandbox settings regardless of host config
- **Environment composable**: Same `op inject` pattern as the devcontainer's `use()` function
- **Fully tested**: ~87 assertions across three test suites covering tools, hardening, and launch behavior

### Tradeoffs

- **Image size (~1.9 GiB)**: Ansible collections account for ~470 MB. Could be reduced by switching to `ansible-core` and shipping only needed collections, but this limits the agent's ability to work across repos
- **No `--read-only` root filesystem**: Claude Code's writable path requirements at `$HOME` root prevent this. Mitigated by ephemeral containers (`--rm`) and other filesystem restrictions
- **Separate session history**: Container and host Claude sessions have independent histories — a session started in the container cannot be resumed from the host and vice versa
- **Conditional flags**: `--init` and `--memory` are skipped in environments without catatonit or cgroup delegation, slightly reducing hardening in nested containers
- **Credential seeding is one-time**: If host credentials are refreshed (e.g., OAuth token rotation), `~/.claude/.credentials.json` must be manually deleted to re-seed

### Security considerations

- The container is ephemeral (`--rm`) — any changes outside mounted volumes are discarded
- Sandbox settings are enforced even if the host's `~/.claude/settings.json` has no sandbox config (entrypoint merge ensures baked settings take precedence)
- `GITHUB_TOKEN` (when provided via `-e`) is visible in the process environment inside the container — same exposure model as [ADR-0001](0001-environment-switching-with-1password.md)
- The agent has full read-write access to the mounted workspace (`$PWD:$PWD`) — scope the working directory appropriately
- Core dumps are disabled (`--ulimit core=0`) to prevent credential leakage via crash dumps
