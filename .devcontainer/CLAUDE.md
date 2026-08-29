# Devcontainer context

You are running inside a CentOS Stream 10 devcontainer based development environment used to work on homelab repos.

## What this container is

- Dev environment for the workspaces pre-cloned at `/workspace/` on the host and bind-mounted in.
- Has internet access and package managers (`dnf`, `pip`) available — though pip installs go to the ephemeral container filesystem and are lost on rebuild.
- CLI tools installed via mise from `/workspace/igou-devenv/mise.toml` (kubectl, helm, kustomize, argocd, oc, virtctl, terraform, gh, etc.) plus Ansible ecosystem via pip.
- Rootless podman available for nested container work (`/dev/fuse`, `/dev/net/tun` passed through, `--privileged`).
- SSH: container-local ssh-agent on `$SSH_AUTH_SOCK=/tmp/ssh-agent.sock`, started empty; load keys from 1Password with `ssh-use` (adr/0004). No host agent forwarding, no private keys on disk. `~/.ssh` (config/known_hosts only), `~/.gitconfig`, and `~/.config/op` are bind-mounted.
- Shell functions `use <env>` (1Password-backed env switching; `use` alone lists envs) and `ssh-use`/`ssh-unuse` are available in non-interactive Bash tool calls (sourced from `~/.bashrc.d`). `use` env vars last only for that one call, so chain them: `use ocp-cluster-reader && oc get nodes`. `ssh-use` persists across calls (shared agent).
- 1Password CLI (`op`) available — secrets resolved via `op inject`, never stored.
