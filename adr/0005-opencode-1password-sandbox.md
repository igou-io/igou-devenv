# ADR-0005: Sandbox opencode from 1Password Credentials

## Status

Accepted

## Date

2026-08-25

## Context

opencode runs coding agents that execute arbitrary shell commands. In this
devcontainer those agents are driven headlessly by t3 (the always-on
`t3 serve`), which spawns one `opencode serve` per project and connects to it.
Nothing between the model and the shell prevents an agent from reading the
host's 1Password credentials and exfiltrating secrets.

`op` on this host runs in **1Password Connect mode** (adr/0003). The Connect
token is not in the environment; it lives only in `~/.config/op/`
(`connect-token`, `connect-host`, or the `service-account-token` fallback), a
read-only bind mount. `dotfiles/.bashrc` exports `OP_CONNECT_HOST`/
`OP_CONNECT_TOKEN` (or `OP_SERVICE_ACCOUNT_TOKEN`) **only** from those files;
t3 itself carries no `OP_*` variables. So the credential has exactly one source
on disk.

opencode's own permission system (per-agent `permission.bash` globs) is not a
boundary for this. Its matcher is defeated by absolute paths (`/usr/bin/op`),
`sh -c`, redirection, `find -exec`, wrapper scripts, and non-bash tool paths; a
`{"op*": deny}` rule does not keep a determined agent away from the token, nor
from a hand-rolled `curl` to the Connect REST API. (Confirmed: `GET
$OP_CONNECT_HOST/v1/vaults` returns 200 with the token, 401 without.)

## Decision

Run the real opencode binary behind a shim
(`.devcontainer/opencode-1password-sandbox`) that isolates it from the token at
the OS level:

- `unshare --mount --map-root-user` gives opencode a private mount namespace.
- A `tmpfs` is mounted over `~/.config/op`, so the token files are absent for
  opencode and every command it spawns. With no files, `.bashrc` exports no
  `OP_*`, and `op` / the Connect API have no credential.
- `setpriv --bounding-set -sys_admin` drops `CAP_SYS_ADMIN` **after** masking
  and before exec'ing opencode. This is load-bearing: inside the namespace the
  process is root and could otherwise `umount` the tmpfs (or nest a fresh user
  namespace) to re-expose the underlying token. Dropping the capability from the
  bounding set blocks both routes.
- Fail-closed: if the namespace or mask cannot be created, opencode does not run.

The shim is installed at `~/.local/bin/opencode-sandbox` and the
`~/.local/bin/opencode` symlink (first `opencode` on `PATH`) points at it, so
t3's default `binaryPath: "opencode"` resolves to it with no t3 configuration
change. The real binary stays at `~/.opencode/bin/opencode`.

## Consequences

- **Scope is all opencode in the container** (t3-launched and a direct
  `opencode` CLI), because it swaps the shared symlink. Unsandboxed access
  remains available at `~/.opencode/bin/opencode` for deliberate use.
- **uid is 0 inside the namespace.** `--map-root-user` is required to obtain the
  mount capability; it maps back to `igou` on the host, so files opencode
  creates stay `igou`-owned. `sudo` may complain inside the namespace;
  `oc`/`kubectl`/`git`/`ansible` are unaffected.
- This blocks **1Password specifically**, not general egress. The agent can
  still reach its model endpoint, GitHub, etc. Broader network isolation would
  require a container/netns (see Alternatives).
- The Dockerfile verifies the real binary directly (`"$DEST/opencode"
  --version`) rather than through the shim, because the build environment may
  not permit user namespaces and the shim is fail-closed. The shim is exercised
  at runtime by `tests/test-opencode-sandbox.sh`.

## Alternatives considered

- **opencode permission globs** — rejected as a boundary; leaky matcher (see
  Context). Still useful as defense-in-depth / a tripwire.
- **Rootless podman with `--userns keep-id` and no `~/.config/op` mount** —
  stronger (preserves uid, allows a real network boundary), but needs an image
  with the full toolchain and careful mounts/env. Deferred; the namespace shim
  achieves the token-isolation goal with far less machinery.

## References

- adr/0003 — Default to 1Password Connect
- `.devcontainer/opencode-1password-sandbox`, `.devcontainer/Dockerfile`
  (opencode block), `tests/test-opencode-sandbox.sh`
