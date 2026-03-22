#!/usr/bin/env bash
# Host-side initialization — runs before the container is built.
# Creates directories required by bind mounts so they don't fail on hosts
# (including CI runners) where these paths may not exist yet.
set -euo pipefail

for dir in "$HOME/.claude" "$HOME/.ssh" "$HOME/.kube" "$HOME/.config/argocd" "$HOME/.config/op" "$HOME/.config/envs" "$HOME/.terraform.d" "$HOME/workspace" "$HOME/rosa-gitops" "$HOME/rosa-gitops-example-team"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "[init] Created $dir"
    fi
done

# Ensure .claude.json exists for bind mount (file, not directory)
if [ ! -f "$HOME/.claude.json" ]; then
    echo '{}' > "$HOME/.claude.json"
    echo "[init] Created $HOME/.claude.json"
fi
