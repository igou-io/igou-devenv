#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

CONFIG_ROOT="$TESTDIR/openshell"
GATEWAY_DIR="$CONFIG_ROOT/gateways/ocp"
TOKEN_FILE="$GATEWAY_DIR/oidc_token.json"
EXPECTED="$REPO_DIR/dotfiles/openshell/gateways/ocp/metadata.json"

jq -e '
    .mounts | index(
        "source=${localEnv:HOME}/.config/openshell,target=/home/igou/.config/openshell,type=bind"
    ) != null
' "$REPO_DIR/.devcontainer/devcontainer.json" >/dev/null
grep -Fq "\$HOME/.config/openshell" "$REPO_DIR/.devcontainer/init.sh"
grep -Fq '/workspace/igou-devenv/bin/configure-openshell-gateway' \
    "$REPO_DIR/.devcontainer/post-create.sh"

mkdir -p "$GATEWAY_DIR" "$CONFIG_ROOT/gateways/other"
printf '%s\n' '{"gateway_endpoint":"https://stale.invalid"}' >"$GATEWAY_DIR/metadata.json"
printf '%s\n' '{"access_token":"must-survive"}' >"$TOKEN_FILE"
printf '%s\n' '{"name":"other"}' >"$CONFIG_ROOT/gateways/other/metadata.json"
token_before=$(sha256sum "$TOKEN_FILE")

OPENSHELL_CONFIG_HOME="$CONFIG_ROOT" "$REPO_DIR/bin/configure-openshell-gateway"

cmp -s "$EXPECTED" "$GATEWAY_DIR/metadata.json"
[[ "$(sha256sum "$TOKEN_FILE")" == "$token_before" ]]
[[ -f "$CONFIG_ROOT/gateways/other/metadata.json" ]]
[[ "$(stat -c %a "$GATEWAY_DIR")" == "700" ]]
[[ "$(stat -c %a "$GATEWAY_DIR/metadata.json")" == "644" ]]
jq -e '
    .name == "ocp" and
    .gateway_endpoint == "https://openshell.apps.ocp.igou.systems" and
    .auth_mode == "oidc" and
    .oidc_issuer == "https://keycloak.apps.ocp.igou.systems/realms/igou" and
    .oidc_client_id == "openshell-cli" and
    .oidc_audience == "openshell-cli"
' "$GATEWAY_DIR/metadata.json" >/dev/null

metadata_before=$(sha256sum "$GATEWAY_DIR/metadata.json")
OPENSHELL_CONFIG_HOME="$CONFIG_ROOT" "$REPO_DIR/bin/configure-openshell-gateway"
[[ "$(sha256sum "$GATEWAY_DIR/metadata.json")" == "$metadata_before" ]]
[[ "$(sha256sum "$TOKEN_FILE")" == "$token_before" ]]

echo '[OK] declarative OpenShell gateway config'
