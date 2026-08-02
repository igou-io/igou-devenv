# ADR-0004: SSH Keys from 1Password (Replace Agent Forwarding)

## Status

Accepted (design spec and discussion in
[issue #121](https://github.com/igou-io/igou-devenv/issues/121))

## Date

2026-07-10

## Context

SSH access from the devcontainer depended on agent forwarding from the host
through Cursor/VS Code, plus a private key on disk as fallback:

- The Makefile detected the host `SSH_AUTH_SOCK` and bind-mounted it to
  `/tmp/ssh-agent.sock` at container-create time (`SSH_MOUNT`), with a
  stale-mount recreation loop in `make up` because the host socket path is
  regenerated every login session.
- Cursor/VS Code create new socket symlinks on reconnect but leave
  `SSH_AUTH_SOCK` pointing at stale ones. Two workarounds papered over this:
  socket scanning in `post-start.sh` (`find_working_ssh_sock`) and the
  `_fix_ssh_auth_sock` PROMPT_COMMAND hook in `dotfiles/.bashrc`, which probed
  sockets with `timeout 2 ssh-add -l` before every prompt.
- `~/.ssh` is bind-mounted read-write from the host and contained the private
  key (`id_ed25519`), so a privileged key sat on disk at all times regardless
  of forwarding state.

Problems:

1. **Flaky**: forwarding broke on every editor reconnect; the workarounds
   mostly recovered but added per-prompt latency and still failed when no live
   socket existed.
2. **Key at rest**: the fallback private key was always on disk, on the host
   and inside the container, independent of whether SSH was being used.
3. **Editor coupling**: SSH only worked while a Cursor/VS Code session (or a
   host agent) was alive — headless container use had no SSH.

The repo already has an established pattern for this class of problem: secrets
resolved on demand from 1Password via `op` (Connect by default,
service-account fallback — see ADR-0001 and ADR-0003), held only for the
session, cleaned up explicitly.

SSH consumers from the container: GitHub push/pull (github.com/david-igou and
github.com/igou-io), homelab nodes (OpenShift/k3s workers, Armbian boards),
Mikrotik devices on port 3480 (`~/.ssh/config`), and KubeVirt VMs.

## Decision

Run a **container-local ssh-agent** and load private keys into it **on demand
from 1Password** with a bounded lifetime, mirroring the `use`/`unuse` UX.
Remove the dependency on editor agent forwarding entirely. Key material exists
only in 1Password and, transiently, in the in-container agent's memory.

### Architecture

```
1Password vault (lab_ssh)
└── <key-item>            # native "SSH Key" item type
    ├── private key       # op read ...?ssh-format=openssh → ssh-add -
    └── public key        # used by ssh-unuse to remove a single key

bin/ensure-ssh-agent      # idempotent agent bootstrap (standalone, testable)
.devcontainer/post-start.sh  # calls ensure-ssh-agent (non-fatal)
dotfiles/.bashrc          # ssh-use / ssh-unuse; _fix_ssh_auth_sock removed
devcontainer.json         # SSH_AUTH_SOCK=/tmp/ssh-agent.sock (unchanged, now container-local)
Makefile                  # SSH_MOUNT forwarding + stale-mount recreation removed
```

### Agent lifecycle

`bin/ensure-ssh-agent` (called by `post-start.sh`, replacing
`find_working_ssh_sock`) starts a dedicated agent on the fixed socket path
that `containerEnv` already exports. It reuses a live agent (`ssh-add -l`
exit code ≤ 1), replaces a dead or stale socket, and warns without failing
post-start when the path is an unremovable mountpoint left by a pre-ADR-0004
container.

- Every terminal shares the one agent — same UX as forwarding, without the
  reconnect fragility.
- The socket lives on the container's own `/tmp`, never on a bind mount.
- The agent dies with the container; keys never persist across rebuilds.
- The agent starts **empty**. Auto-loading a key would reproduce the
  "privileged credential ambient at all times" posture this ADR removes,
  just in memory instead of on disk.

### Shell functions

```bash
ssh-use                  # load the default key (op://lab_ssh/github)
ssh-use <item>           # load op://lab_ssh/<item>
SSH_USE_TTL=1h ssh-use   # override the default 12h lifetime
SSH_USE_VAULT=v ssh-use  # override the default vault (lab_ssh)
ssh-unuse <item>         # remove one key (via its public half)
ssh-unuse                # remove all keys
```

`ssh-use` pipes `op read "op://<vault>/<item>/private key?ssh-format=openssh"`
straight into `ssh-add -t <ttl> -`: the key goes from 1Password into agent
memory without touching a file, and expires from the agent after the TTL.
Failure behavior follows ADR-0001 conventions — fail loudly, nonzero return,
agent state unchanged. Re-running `ssh-use` is idempotent (re-adds, resets
the TTL).

### Key hygiene: dedicated devcontainer keypair

The vault holds a **dedicated keypair generated for this environment**, not
the personal `id_ed25519`:

- Its public key is authorized on GitHub (both accounts), homelab
  `authorized_keys` (fleet rollout via the Ansible inventory), and Mikrotik
  devices.
- The blast radius of the op credential is "the devcontainer key", revocable
  everywhere in minutes — not the personal key.
- Once migration is verified, private keys are removed from host `~/.ssh` and
  the old public key is de-authorized. `~/.ssh` stays bind-mounted for
  `config`, `known_hosts`, and `authorized_keys` only.

### 1Password item

Native **SSH Key** item type (not a base64 text field — unlike kubeconfigs,
1Password handles SSH keys as first-class multi-line items and `op` re-encodes
them to OpenSSH format on read). Item creation happens via the desktop app or
a write-capable credential; the in-container Connect credential stays
read-only (ADR-0003).

## Consequences

### Benefits

- **No forwarding**: editor reconnects are irrelevant; `_fix_ssh_auth_sock`,
  `find_working_ssh_sock`, the Makefile `SSH_MOUNT`/stale-mount-recreation
  machinery, and the per-prompt `ssh-add -l` probes are all deleted.
  Headless/tmux sessions get SSH without an editor attached.
- **No private key at rest**: not on the host, not in the container, not in
  the image. Key material exists in 1Password and transiently in agent memory
  with a TTL.
- **Consistent pattern**: same mental model and failure behavior as
  `use`/`unuse` (ADR-0001); same auth chain (ADR-0003).
- **Explicit, auditable state**: `ssh-add -l` shows exactly which keys are
  loaded, and nothing loads implicitly at startup.

### Tradeoffs

- **Key material becomes readable via the op credential.** Agent forwarding
  never exposed the private key to the container — only signing operations.
  With this design, anyone holding the (disk-resident, read-only-mounted)
  Connect token can fetch the key. Mitigations: dedicated low-blast-radius
  keypair, agent TTL, vault scoping so the Connect token sees only what the
  devcontainer needs. This matches the trust already extended for kubeconfigs
  and AWS credentials (ADR-0001) on a trusted single-user workstation.
- One manual `ssh-use` per container lifetime (or after TTL expiry) replaces
  always-on ambient credentials. That friction is the point.
- An `op` outage (Connect and service-account both unavailable) means no new
  key loads until restored; already-loaded agent keys keep working.
- Host-side git/SSH no longer has a key on disk either — the host should use
  the 1Password desktop app's native SSH agent (out of scope for this repo).

### Security considerations

- The agent socket is container-local and never bind-mounted.
- `ssh-add -t` bounds the window a compromised container session can sign
  with the key; `ssh-unuse` clears it immediately.
- The agent deliberately starts empty (see Agent lifecycle).

## Testing

`tests/test-ssh.sh` covers the agent bootstrap (fresh start, reuse, stale
socket replacement, starts-empty invariant) and `ssh-use`/`ssh-unuse` (load,
idempotency, loud failure with unchanged agent state, selective and full
removal, TTL expiry) using `tests/mock-op.sh` and a real ssh-agent on a
test-private socket. It runs in CI (no interactive shell needed) via
`tests/run-all.sh` and locally via `make test-ssh`.

## Migration

1. Create the dedicated keypair; store it as an SSH Key item in `lab_ssh`;
   authorize the public key on GitHub (both orgs), homelab nodes (Ansible),
   and network devices.
2. Land the container changes (this ADR's implementation PR).
3. Verify: fresh container → `ssh-use` → `git pull`/`push` against both
   GitHub orgs, SSH to a homelab node and a Mikrotik device, TTL expiry,
   editor reconnect no longer affecting SSH.
4. Decommission: remove private keys from host `~/.ssh`, de-authorize the old
   public key everywhere.
