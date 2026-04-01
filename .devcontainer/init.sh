#!/usr/bin/env bash
# Host-side initialization — runs before the container is built.
# Creates directories required by bind mounts so they don't fail on hosts
# (including CI runners) where these paths may not exist yet.
set -euo pipefail

for dir in "$HOME/.claude" "$HOME/.claude-container" "$HOME/.config/cursor" "$HOME/.ssh" "$HOME/.kube" "$HOME/.config/argocd" "$HOME/.config/op" "$HOME/.terraform.d" "$HOME/workspace" "$HOME/rosa-gitops" "$HOME/rosa-gitops-example-team"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "[init] Created $dir"
    fi
done

# Ensure file-based bind mounts exist (files, not directories)
if [ ! -f "$HOME/.claude.json" ]; then
    echo '{}' > "$HOME/.claude.json"
    echo "[init] Created $HOME/.claude.json"
fi
if [ ! -f "$HOME/.gitconfig" ]; then
    touch "$HOME/.gitconfig"
    echo "[init] Created $HOME/.gitconfig"
fi
