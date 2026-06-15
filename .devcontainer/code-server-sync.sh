#!/usr/bin/env bash
# Bridge devcontainer.json's customizations.vscode {settings, extensions} into a
# code-server data directory.
#
# code-server (browser VS Code) does NOT read devcontainer.json — that metadata
# is only applied by the VS Code Dev Containers *client* when it attaches. This
# repo launches code-server directly (post-start.sh), so without this bridge the
# editor settings (file associations, yaml schemas) and language extensions
# (syntax highlighting) defined in devcontainer.json never reach code-server.
#
# Single source of truth: .devcontainer/devcontainer.json. Called from two paths:
#   - Dockerfile (build): bakes into the image's default data dir → serves `make run`
#   - post-start.sh (start): populates the bind-mounted data dir → serves `make up`
#
# Usage: code-server-sync.sh <devcontainer.json> <code-server-data-dir>
set -euo pipefail

DEVCONTAINER_JSON="${1:?usage: code-server-sync.sh <devcontainer.json> <data-dir>}"
DATA_DIR="${2:?usage: code-server-sync.sh <devcontainer.json> <data-dir>}"

command -v jq >/dev/null 2>&1 || { echo "code-server-sync: jq not found" >&2; exit 1; }
command -v code-server >/dev/null 2>&1 || { echo "code-server-sync: code-server not found" >&2; exit 1; }

# --- Settings: write customizations.vscode.settings to the Machine scope ------
# Machine scope is the devcontainer-owned layer — it mirrors what VS Code Dev
# Containers does (writes these to the remote machine's settings) and overrides
# User settings, so the user's own User/settings.json (theme, etc.) is untouched.
# Overwritten every run: this scope is owned by devcontainer.json, not the user.
mkdir -p "$DATA_DIR/Machine"
jq '.customizations.vscode.settings // {}' "$DEVCONTAINER_JSON" > "$DATA_DIR/Machine/settings.json"
echo "code-server-sync: wrote $DATA_DIR/Machine/settings.json"

# --- Extensions: install those available on Open VSX --------------------------
# code-server pulls from Open VSX, not the MS marketplace, so a few MS/Cursor
# extensions in devcontainer.json have no Open VSX build; those are skipped with
# a warning (they provide no syntax grammars anyway). Idempotent: already-present
# extensions are skipped so warm starts don't hit the network.
EXT_DIR="$DATA_DIR/extensions"
mkdir -p "$EXT_DIR"
installed="$(code-server --extensions-dir "$EXT_DIR" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    if printf '%s\n' "$installed" | grep -qxF "$ext_lc"; then
        continue
    fi
    if code-server --extensions-dir "$EXT_DIR" --install-extension "$ext" >/dev/null 2>&1; then
        echo "code-server-sync: installed $ext"
    else
        echo "code-server-sync: WARN $ext not installed (likely absent from Open VSX)"
    fi
done < <(jq -r '.customizations.vscode.extensions // [] | .[]' "$DEVCONTAINER_JSON")
