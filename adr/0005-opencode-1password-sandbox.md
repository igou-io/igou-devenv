# ADR-0005: Sandbox opencode from 1Password Credentials

## Status

Accepted

## Date

2026-08-25

## Context

opencode runs coding agents that execute arbitrary shell commands. In this
devcontainer those agents are driven headlessly by t3 (the always-on
`t3 serve`), which spawns an `opencode serve` process (via the provider's
`binaryPath`) and connects to it. Nothing between the model and the shell
prevents an agent from reading the host's 1Password credentials and
exfiltrating secrets.

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

## Additional provider: credential-injecting container instance

The namespace shim above makes the **default** opencode safe (no 1Password). On
top of that we add an **opt-in** way to give a t3 opencode session a specific,
static credential set — for example a read-only cluster kubeconfig — without ever
exposing the 1Password token.

t3 supports multiple **provider instances** (`providerInstances` in its
settings): each instance has its own `driver`, `config` (including `binaryPath`),
and natively-injected `environment`. A new instance is fully independent of the
default opencode provider, which is untouched.

We add an instance (driver `opencode`) whose `binaryPath` is
`~/.local/bin/opencode-sandbox-launch` (`.devcontainer/opencode-sandbox-launch`, baked into
the image). When t3 spawns it (`serve …`, or the `--version`/`agent list` probes)
the launcher:

- resolves the profile named by the instance's `OPENCODE_SANDBOX_PROFILE`
  environment variable (an `envs/<profile>.env` file) via `op inject` **on the
  host**, exactly like `bin/opencode-run`;
- runs opencode in a hardened rootless container (`--cap-drop=ALL`,
  `--userns=keep-id`, `--security-opt no-new-privileges`, tmpfs, resource limits)
  with `--network=host` so t3 reaches the `serve` listener, the workspace and
  opencode config/state mounted, and **`~/.config/op` never mounted**;
- injects only the resolved credentials as `-e KEY=VALUE` (+ a read-only
  kubeconfig temp mount). Secrets are resolved at launch and never stored in t3.

Because credentials are resolved on the host and the token directory is not
mounted, the agent gets exactly the profile's credentials and no path back to
1Password. Diagnostics go to stderr so t3's stdout parsing (version string, the
`opencode server listening on <url>` ready line) is unaffected.

Example instance to add in t3 (Settings → Providers), leaving the default
opencode as-is:

```jsonc
// providerInstances["opencode-ro"]
{
  "driver": "opencode",
  "displayName": "opencode ▸ readonly cluster",
  "config": { "binaryPath": "/home/igou/.local/bin/opencode-sandbox-launch" },
  "environment": [
    { "name": "OPENCODE_SANDBOX_PROFILE", "value": "ocp-cluster-reader" }
  ]
}
```

Any `envs/*.env` becomes a profile; `OPENCODE_SANDBOX_PROFILE=none` (or unset)
injects nothing. Provider instances live in t3's `~/.t3` state (runtime user
config, like pairing tokens), so this one line of setup is not image-declarative;
the launcher, image wiring, and test are.

## Alternatives considered

- **opencode permission globs** — rejected as a boundary; leaky matcher (see
  Context). Still useful as defense-in-depth / a tripwire.
- **Overriding the default opencode `binaryPath`** with the container launcher —
  rejected: it would containerize *all* opencode (t3 runs one shared opencode
  server keyed by `binaryPath`) and couple every session to podman + a pullable
  image. An additional provider instance keeps the default fast and unchanged.
- **Injecting credentials via t3's native per-instance `environment`** instead of
  `op inject` at launch — rejected for secrets: it would store the kubeconfig/
  token in t3's `~/.t3` state. We use `environment` only for the non-secret
  profile *selector* (`OPENCODE_SANDBOX_PROFILE`).

## References

- adr/0003 — Default to 1Password Connect
- `.devcontainer/opencode-1password-sandbox`, `.devcontainer/opencode-sandbox-launch`,
  `.devcontainer/Dockerfile` (opencode block), `envs/*.env`,
  `tests/test-opencode-sandbox.sh`, `tests/test-opencode-instance.sh`
