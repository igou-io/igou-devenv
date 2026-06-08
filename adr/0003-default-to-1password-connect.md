# ADR-0003: Default to 1Password Connect for Secret Resolution

## Status

Accepted

## Date

2026-06-08

## Context

The devcontainer shell authenticates the `op` CLI so that the `use <env>` /
`unuse` functions, `op inject`, and the `op://` references in `envs/*.env`
(see [ADR-0001](0001-environment-switching-with-1password.md)) can resolve
secrets. Until now, `op` authenticated exclusively via
`OP_SERVICE_ACCOUNT_TOKEN`, sourced from
`~/.config/op/service-account-token`.

1Password **service accounts** are subject to an API rate limit on
`1password.com` (1000 reads/hour, plus a daily `account read_write` cap).
Secret-heavy runs — e.g. activating several environments, or an agent that
re-resolves credentials frequently — can exhaust this budget and start
failing with rate-limit errors.

We already run a self-hosted **1Password Connect** server
(`https://onepassword-connect-onepassword-connect.apps.ocp.igou.systems`, an
internal OCP route). Connect reads are served by that server, not the
`1password.com` service-account API, so they are **not** subject to the
service-account rate limit. The `op` CLI supports Connect via the
`OP_CONNECT_HOST` + `OP_CONNECT_TOKEN` environment variables.

Verified before adopting:

- `op read` and `op inject` — the only `op` subcommands in the runtime path —
  both work in Connect mode.
- The Connect token's scope covers every vault the shells resolve today
  (`claude` and `awx`).
- When both `OP_CONNECT_*` and `OP_SERVICE_ACCOUNT_TOKEN` are set, `op`
  prefers Connect.

## Decision

Authenticate `op` via **1Password Connect by default**, falling back to the
service-account token only when the Connect credentials are absent.

The auth block in `dotfiles/.bashrc` becomes (Connect preferred,
service-account as fallback):

```bash
if [ -f ~/.config/op/connect-host ] && [ -f ~/.config/op/connect-token ]; then
    export OP_CONNECT_HOST=$(cat ~/.config/op/connect-host)
    export OP_CONNECT_TOKEN=$(cat ~/.config/op/connect-token)
elif [ -f ~/.config/op/service-account-token ]; then
    export OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op/service-account-token)
fi
```

The `elif` (rather than two independent `if`s) ensures that when Connect is
active we do **not** also export the service-account token, so `op` never
spends the rate-limited service-account budget.

The Connect credential files live on the host at `~/.config/op/connect-host`
and `~/.config/op/connect-token`. Because `~/.config/op` is already
bind-mounted read-only into the container (see `devcontainer.json`), no mount
change is needed.

`OP_CONNECT_TOKEN` is also added to the `CURSOR_AGENT` secret-strip block in
`dotfiles/.bashrc`, alongside `OP_SERVICE_ACCOUNT_TOKEN`.

This changes only the **developer shell**. The AAP/AWX execution environment
still receives its token via AAP credentials; migrating that to Connect is
tracked separately.

## Consequences

### Benefits

- **No service-account rate limit**: Connect reads hit the self-hosted
  server, removing the 1000-reads/hour throttle on secret-heavy runs.
- **Non-breaking**: nothing downstream cares *how* `op` authenticates — the
  `use`/`unuse` functions, `op inject`/`op read` call sites, and `envs/*.env`
  references are untouched.
- **Fallback intact**: if the Connect files are absent, the shell falls back
  to the service-account token, so existing setups keep working.

### Tradeoffs

- **Availability shifts to the self-hosted server**: secret resolution now
  depends on the Connect server (an internal OCP route) being reachable. The
  service-account fallback is the safety net — but only kicks in when the
  Connect *files* are absent, not when the server is merely unreachable.
- **Off-LAN**: the Connect host is an internal OCP route that resolves
  **on-LAN only**. With the plain `elif`, if the Connect files are present
  but the server is unreachable, `op` fails instead of falling back. (A
  heartbeat-gated variant was considered and rejected to avoid adding shell
  startup latency; remove the Connect files to force the SA fallback when
  working off-LAN for an extended period.)
- **Token scope**: the Connect token must cover every `op://<vault>/` the
  shells resolve. Currently `claude` + `awx`, both in scope. New `envs/` or
  sibling-repo references that add a vault must confirm it's in the token's
  scope.

### Security considerations

- `~/.config/op/connect-token` is a bearer token granting read access across
  the scoped vaults. Store it mode `600`, never commit it, and rotate on
  leak. It is bind-mounted read-only into the container.
- The Connect credential files contain secrets and live only on the host —
  they are never checked into the repo.
