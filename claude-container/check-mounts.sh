#!/bin/bash
echo "=== Devcontainer HOME: $HOME ==="
echo ""
echo "=== ~/.claude/ contents ==="
ls -la "$HOME/.claude/" 2>&1 | head -15
echo ""
echo "=== Credentials file ==="
ls -la "$HOME/.claude/.credentials.json" 2>&1
echo ""
echo "=== claude-run dry-run ==="
claude-run --dry-run --shell 2>&1
echo ""
echo "=== What podman sees inside nested container ==="
podman run --rm --userns=keep-id \
    -v "$HOME/.claude:/home/igou/.claude:Z" \
    claude-devenv bash -c 'echo "Container HOME=$HOME"; ls -la $HOME/.claude/ | head -10; echo ---; ls -la $HOME/.claude/.credentials.json 2>&1; echo ---; cat $HOME/.claude/.credentials.json 2>/dev/null | head -c 50; echo'
