#!/usr/bin/env bash
# Dev Spaces postStart bootstrap — the devfile equivalent of post-create.sh.
# Devcontainer lifecycle hooks don't run under Dev Spaces and the workspace
# has no host bind mounts, so seed shell/ghapp config from the cloned repo,
# register the arbitrary runtime UID, and start the ssh-agent ssh-use expects.
set -euo pipefail

REPO="${PROJECT_SOURCE:-/projects/igou-devenv}"

# Register the arbitrary OpenShift UID in /etc/passwd (group-writable in the
# image) so tools that resolve the current user (ssh, ansible, whoami) work.
# Registered as "igou" so igou's /etc/subuid ranges apply to rootless podman.
if ! whoami >/dev/null 2>&1; then
    echo "igou:x:$(id -u):0:igou:/home/igou:/bin/bash" >> /etc/passwd
fi

echo "==> Configuring shell..."
cp "$REPO/dotfiles/.bashrc" /home/igou/.bashrc
mkdir -p /home/igou/.bashrc.d
cp "$REPO/dotfiles/.bashrc.d"/*.sh /home/igou/.bashrc.d/
cp "$REPO/dotfiles/tmux.conf" /home/igou/.tmux.conf

# ghapp config: seed only if absent, mirroring post-create.sh (non-secret —
# IDs only; the App private key is read from 1Password at mint time).
echo "==> Installing ghapp config (first run only)..."
mkdir -p /home/igou/.config/ghapp
if [ ! -f /home/igou/.config/ghapp/config.yaml ]; then
    cp "$REPO/dotfiles/ghapp/config.yaml" /home/igou/.config/ghapp/config.yaml
    chmod 600 /home/igou/.config/ghapp/config.yaml
fi

ln -sfn "$REPO/bin" /home/igou/bin

# Container-local ssh-agent, same socket path as the devcontainer (ADR-0004);
# keys are loaded on demand with ssh-use.
[ -S /tmp/ssh-agent.sock ] || ssh-agent -a /tmp/ssh-agent.sock >/dev/null

echo "==> Dev Spaces bootstrap complete"
