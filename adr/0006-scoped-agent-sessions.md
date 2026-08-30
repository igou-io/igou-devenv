# ADR-0006: Scoped agent sessions via a profile-injecting launcher

## Status

Accepted

## Date

2026-08-29

## Context

Every agent session in the devcontainer (Claude Code, Codex, opencode — local or
spawned by t3) ran with the same ambient power: `~/.config/op` mounted, so `use ocp`
yields system:admin and `ssh-use` loads any lab key. The only thing between an agent
and full cluster admin was prose in CLAUDE.md. ADR-0005 fixed this for the *default*
opencode (no credentials at all) and added one hand-built t3 instance with a static
read-only kubeconfig — but that launcher was opencode-only, duplicated the env-file
resolution logic (a third copy, after `use()` and `bin/*-run`), and had no equivalent
for Claude or Codex, which are the sessions that do most of the work.

What was wanted: "a t3 session that has exactly this identity" — read-only on OCP in
one session, admin on rk8s plus the Ansible SSH key in another — chosen when the
session is created, not escalated from inside.

## Decision

- **The profile is the unit of scope.** A session is launched with one or more
  `envs/*.env` profiles (stackable, later wins). Everything the profile resolves to —
  kubeconfig, registry auth, plain vars — is injected at launch. Two new
  profile keys are interpreted by the launcher: `SSH_KEYS=<lab_ssh items>` and
  `PERMISSIONS=readonly|guarded`.
- **One resolver.** `bin/resolve-profile` is the single implementation of env-file
  resolution (atomic: nothing printed and no temp files on failure). `use()`, every
  `bin/*-run` and the launcher all call it.
- **One launcher for three drivers.** `.devcontainer/agent-sandbox-launch` (baked to
  `~/.local/bin`) runs claude, codex or opencode in the hardened rootless container
  from ADR-0005, with the driver inferred from t3's own arguments
  (`app-server` → codex, `serve` → opencode, otherwise claude). t3 provider instances
  point `binaryPath` at it and select the scope with `AGENT_SANDBOX_PROFILES` in the
  instance environment. Everything t3 passes is forwarded verbatim; stdout is the
  agent protocol, diagnostics go to stderr.
- **No 1Password in the container, ever.** Profiles are resolved on the host; the
  container gets env vars and read-only mounts. There is no `use`, `ssh-use` or `op`
  inside, so the scope cannot grow mid-session. Changing scope = new session from a
  different instance.
- **SSH keys are per session.** `SSH_KEYS` items are read on the host, mounted
  read-only for the container's lifetime and loaded into an `ssh-agent` that lives
  and dies with the container. The shared host agent socket is never mounted, so one
  session's keys are never visible to another.
- **Two layers of permission.** The credential's RBAC is the hard boundary. The
  `PERMISSIONS` level is the soft one: per-driver fragments in `envs/permissions/`
  (Claude `settings.json` deny/ask lists, Codex `sandbox_mode`/`approval_policy`,
  opencode `permission` block) applied into a per-scope home so mutations are denied
  (`readonly`) or ask in the t3 UI (`guarded`).
- **The Claude sandbox is a container-only layer.** The bwrap/seccomp `sandbox`
  block lives in `envs/permissions/<level>/claude.json`, not in the user's
  `~/.claude/settings.json`, and the launcher fails closed if the rendered scope
  settings don't enable it. Unscoped sessions in the devcontainer therefore run
  without a Claude sandbox; scoped ones always have it, with an allowlist sized to
  the scope (Anthropic, GitHub, the cluster/API hosts the profile reaches).
- **The agent knows its scope.** The launcher writes a scope note (profiles,
  permission level, "there is no `use`/`op` here; ask for a different session") into
  the per-scope Claude `CLAUDE.md` / `CODEX_HOME/AGENTS.md` / an opencode
  `instructions` file, and exports `AGENT_PROFILE`.
- **Per-scope homes.** `~/.claude-<profiles>` and `~/.codex-<profiles>` (auth seeded
  from the real home, history and state not shared); opencode keeps its shared
  config/state because it has no per-home auth.

## Consequences

- t3 gets one provider instance per scope (`Claude ▸ OCP read-only`,
  `Codex ▸ OCP read-only`, `Claude ▸ rk8s admin + ansible`, …) next to the stock
  full-power providers, which stay as they are.
- opencode still needs one shim per profile (`agent-sandbox-launch --install-shim
  <profile>`) because t3 keeps a single shared `opencode serve` per `binaryPath`;
  Claude and Codex select by env.
- A Codex runtime image (`ghcr.io/igou-io/codex`) must exist for the codex driver
  (igou-containers `apps/codex`, same shape as `apps/opencode`).
- `opencode-sandbox-launch` remains as a back-compat shim mapping
  `OPENCODE_SANDBOX_*` to `AGENT_SANDBOX_*`.
- `envs/rk8s.env` is admin-only; a read-only rk8s profile needs a published SA token
  (same pattern as `ocp-cluster-reader`).

## Alternatives considered

- **Per-prompt permission picker only (opencode agents).** Controls tools, not
  credentials; the agent could still `use ocp`. Kept as the soft layer, not the
  boundary.
- **Claude sandbox settings alone.** Same problem — it constrains the tool, not what
  the mounted 1Password can mint.
- **One launcher per driver.** Three copies of the hardening and resolution logic;
  that is exactly the drift ADR-0006 removes.

## References

- ADR-0001 (env switching), ADR-0004 (SSH keys), ADR-0005 (opencode sandbox)
- igou-docs: `devenv/T3 Code Remote Agent GUI.md` — "Scoped sessions (profiles)"
