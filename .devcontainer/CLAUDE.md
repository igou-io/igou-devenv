# Devcontainer context

You are running inside a CentOS Stream 10 devcontainer based development environment used to work on homelab repos.

## What this container is

- Dev environment for the workspaces pre-cloned at `/workspace/` on the host and bind-mounted in.
- Has internet access and package managers (`dnf`, `pip`) available — though pip installs go to the ephemeral container filesystem and are lost on rebuild.
- CLI tools installed via mise from `/workspace/igou-devenv/mise.toml` (kubectl, helm, kustomize, argocd, oc, virtctl, terraform, gh, etc.) plus Ansible ecosystem via pip.
- Rootless podman available for nested container work (`/dev/fuse`, `/dev/net/tun` passed through, `--privileged`).
- SSH agent forwarded from host via `$SSH_AUTH_SOCK=/tmp/ssh-agent.sock`. `~/.ssh`, `~/.gitconfig`, and `~/.config/op` are bind-mounted read-only.
- 1Password CLI (`op`) available — secrets resolved via `op inject`, never stored.
