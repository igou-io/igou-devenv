# ADR-0002: Kubernetes MCP Server for Claude Code

## Status

Accepted

## Date

2026-03-23

## Context

The devcontainer manages multiple Kubernetes/OpenShift clusters via the `use()` environment switching function (see [ADR-0001](0001-environment-switching-with-1password.md)). When working with Claude Code, cluster interactions currently require explicitly asking Claude to run `kubectl` or `oc` commands. An MCP (Model Context Protocol) server gives Claude direct cluster access — it can query resources, read logs, and inspect state without being prompted to shell out.

### Requirements

- Work across all repos under `/workspace/`, not just the devenv repo
- Integrate with the existing `use()` environment switching for cluster selection
- Support both read-only (auditing, debugging) and read-write (applying changes) workflows
- Provide OpenShift-native support for ocp-hub, ocp-casval, ocp-rosa clusters

## Decision

Install **`containers/kubernetes-mcp-server`** as a user-level MCP server in Claude Code, configured via `claude mcp add -s user`.

### Why this server

- Maintained by the `containers` GitHub org (Red Hat — same ecosystem as podman, buildah, skopeo already in the devenv)
- Native Go Kubernetes client — no kubectl dependency (though kubectl is available)
- First-class OpenShift support (projects, routes, etc.)
- Configurable safety modes: `--read-only` and `--disable-destructive`
- Available via `npx kubernetes-mcp-server@latest`

### Why user-level (not project-scoped)

MCP servers configured in `.mcp.json` are only discovered when Claude is launched from that project directory. Since the devenv hosts multiple repos under `/workspace/` (igou-ansible, igou-kubernetes, igou-infrastructure, etc.), a project-scoped config in the devenv repo would not be available when working in other repos. User-level config (`-s user`) is stored in `~/.claude.json`, which is bind-mounted from the host and persists across container rebuilds.

### Installation

```bash
claude mcp add -s user kubernetes -- npx -y kubernetes-mcp-server@latest
```

This registers the server globally. Verify with:

```bash
claude mcp list
```

## Workflows

### Connecting to a cluster

The MCP server inherits the shell environment. Use the `use()` function to set `KUBECONFIG` before starting Claude:

```bash
use ocp-rosa                # resolves secrets, sets KUBECONFIG
claude                      # MCP server inherits KUBECONFIG, connects to ocp-rosa
```

Claude can now directly query the cluster (list pods, read logs, describe resources) using MCP tools.

**Important**: The MCP server captures the environment at Claude startup. If you need to switch clusters, exit Claude and restart:

```bash
# Inside Claude: /exit
exit                        # leave ocp-rosa subshell
use ocp-hub                 # switch to different cluster
claude                      # MCP server now targets ocp-hub
```

### Stacking environments

Environment stacking works as expected — the MCP server sees whatever `KUBECONFIG` is active:

```bash
use ocp-hub                 # sets KUBECONFIG for ocp-hub
use ansible                 # adds Ansible vault vars (no kubeconfig conflict)
claude                      # MCP server connects to ocp-hub, Ansible vars also available
```

### Switching between read-only and read-write

The MCP server supports a `--read-only` flag that disables all mutating operations. Since the server config is static, switching modes requires reconfiguring:

**Set read-only (safer for auditing/debugging):**
```bash
claude mcp remove -s user kubernetes
claude mcp add -s user kubernetes -- npx -y kubernetes-mcp-server@latest --read-only
```

**Set read-write (for applying changes):**
```bash
claude mcp remove -s user kubernetes
claude mcp add -s user kubernetes -- npx -y kubernetes-mcp-server@latest
```

**Tip**: For one-off read-only sessions without reconfiguring, instruct Claude directly: "only read from the cluster, do not create or modify any resources." The MCP tools will still be available but Claude will respect the instruction.

### Without an active environment

If no `KUBECONFIG` is set (no `use` call), the MCP server falls back to the default kubeconfig at `~/.kube/config` (bind-mounted from the host). If no kubeconfig exists, the server starts but cluster operations will fail with connection errors.

## Consequences

### Benefits

- **Direct cluster access**: Claude can inspect resources, read logs, and describe objects without explicit `kubectl` commands
- **Works everywhere**: User-level config means it's available in any repo under `/workspace/`
- **Persists across rebuilds**: Config lives in `~/.claude.json` on the host
- **OpenShift-native**: Supports OpenShift projects, routes, and other custom resources
- **Composable with `use()`**: No additional configuration per cluster — just `use <env>` and start Claude

### Tradeoffs

- **No per-session mode toggle**: Switching read-only/read-write requires `claude mcp remove` + `claude mcp add`
- **Environment captured at startup**: Switching clusters requires restarting Claude
- **npx startup latency**: First invocation downloads the package; subsequent runs use the npm cache
- **Not version-controlled**: User-level config is in `~/.claude.json`, not in the repo — new devenv users must run the `claude mcp add` command manually

### Security considerations

- The MCP server has the same cluster access as the active `KUBECONFIG` — it can do anything `kubectl` can
- Use `--read-only` for clusters where accidental mutations would be costly (production, shared environments)
- The server runs as a subprocess of Claude Code — it does not expose any network ports
- Secrets resolved by `use()` (via `op inject`) are in the process environment and accessible to the MCP server
