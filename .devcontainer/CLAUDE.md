# Devcontainer context

You are running inside the **igou-devenv devcontainer** — a CentOS Stream 10 based development environment used to work on homelab repos. This is NOT the hardened `claude-run` agent container; constraints differ.

## What this container is

- Dev environment for the workspaces pre-cloned at `/workspace/` on the host and bind-mounted in.
- Has internet access and package managers (`dnf`, `pip`) available — though pip installs go to the ephemeral container filesystem and are lost on rebuild.
- CLI tools installed via mise from `/workspace/igou-devenv/mise.toml` (kubectl, helm, kustomize, argocd, oc, virtctl, terraform, gh, etc.) plus Ansible ecosystem via pip.
- Rootless podman available for nested container work (`/dev/fuse`, `/dev/net/tun` passed through, `--privileged`).
- SSH agent forwarded from host via `$SSH_AUTH_SOCK=/tmp/ssh-agent.sock`. `~/.ssh`, `~/.gitconfig`, and `~/.config/op` are bind-mounted read-only.
- 1Password CLI (`op`) available — secrets resolved via `op inject`, never stored.
- `~/.claude` is bind-mounted from the host's `~/.claude-container/` (separate from the host's own `~/.claude/`).
- QEMU userspace available (`qemu-system-x86_64`, `qemu-img`) — for running molecule scenarios that use the `qemu` provisioner. `/dev/kvm` passes through under `--privileged`.

## Conventions

- The devcontainer is rebuilt from `.devcontainer/Dockerfile` + `devcontainer.json`. Persistent tool installs belong in the Dockerfile or `requirements.txt`, not at runtime.
- Bumping CLI tool versions: edit `mise.toml`, run `make mise-lock`, run `make test`. Renovate handles bumps automatically — only intervene if a verification audit flags a regression.
- Before pushing changes to `main`, run `make rebuild && make test` unless the user explicitly waives it.
- See `/workspace/igou-devenv/CLAUDE.md` for full repo guidance.
