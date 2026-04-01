#!/usr/bin/env bash
# Verify installed tools, user config, and Python packages in the cursor-agent container.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# CLI tools — verify they execute, not just exist on PATH
# ---------------------------------------------------------------------------
echo "==> Verifying CLI tools..."

declare -A TOOLS=(
    [kubectl]="kubectl version --client"
    [helm]="helm version --short"
    [gh]="gh --version"
    [python3]="python3 --version"
    [agent]="agent --version"
    [ansible]="ansible --version"
    [argocd]="argocd version --client --short"
    [kustomize]="kustomize version"
    [virtctl]="virtctl version --client"
    [kubeconform]="kubeconform -v"
    [jq]="jq --version"
    [yamllint]="yamllint --version"
    [nmap]="nmap --version"
    [dig]="dig -v"
    [make]="make --version"
    [tkn]="tkn version"
    [mc]="mc --version"
    [rclone]="rclone --version"
    [kubernetes-mcp-server]="kubernetes-mcp-server --version"
)

for tool in $(echo "${!TOOLS[@]}" | tr ' ' '\n' | sort); do
    if version=$(${TOOLS[$tool]} 2>&1 | head -1) && [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool — ${version:-no output}"
    fi
done

# ---------------------------------------------------------------------------
# Python packages (pip removed — verify via importability)
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying Python packages..."

declare -A PY_PACKAGES=(
    [ansible]="import ansible; print(ansible.__version__)"
    [ansible-lint]="from ansiblelint import __version__; print(__version__)"
    [ansible-runner]="import ansible_runner; print('ok')"
    [yq]="import yq; print('ok')"
    [kubernetes]="import kubernetes; print(kubernetes.__version__)"
    [jmespath]="import jmespath; print(jmespath.__version__)"
)

for pkg in $(echo "${!PY_PACKAGES[@]}" | tr ' ' '\n' | sort); do
    if version=$(python3 -c "${PY_PACKAGES[$pkg]}" 2>&1); then
        ok "python: $pkg — $version"
    else
        fail "python: $pkg — ${version:-no output}"
    fi
done

# ---------------------------------------------------------------------------
# Hardening — package managers removed, paths locked
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying hardening..."

if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
    ok "pip/pip3 not available"
else
    fail "pip/pip3 not available (found: $(which pip pip3 2>/dev/null))"
fi

if ! command -v ansible-galaxy &>/dev/null; then
    ok "ansible-galaxy not available"
else
    fail "ansible-galaxy not available"
fi

if ! command -v dnf &>/dev/null && ! command -v rpm &>/dev/null; then
    ok "dnf/rpm not available"
else
    fail "dnf/rpm not available"
fi

if [ ! -w "$HOME/.local/bin" ]; then
    ok "~/.local/bin is read-only"
else
    fail "~/.local/bin is read-only (writable)"
fi

if python3 -c "import site; assert not site.ENABLE_USER_SITE" 2>/dev/null; then
    ok "PYTHONNOUSERSITE active"
else
    fail "PYTHONNOUSERSITE active"
fi

# ---------------------------------------------------------------------------
# Cursor sandbox config baked in
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying sandbox config..."

BAKED_SANDBOX="/etc/cursor/sandbox.json"
if [ -f "$BAKED_SANDBOX" ]; then
    ok "baked sandbox.json exists at /etc/cursor/"
else
    fail "baked sandbox.json exists at /etc/cursor/"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SANDBOX')); assert s['type'] == 'workspace_readwrite'" 2>/dev/null; then
    ok "sandbox type is workspace_readwrite"
else
    fail "sandbox type is workspace_readwrite"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SANDBOX')); assert s['networkPolicy']['default'] == 'deny'" 2>/dev/null; then
    ok "network default policy is deny"
else
    fail "network default policy is deny"
fi

if python3 -c "import json; s=json.load(open('$BAKED_SANDBOX')); assert 'github.com' in s['networkPolicy']['allow']" 2>/dev/null; then
    ok "github.com in network allow list"
else
    fail "github.com in network allow list"
fi

# ---------------------------------------------------------------------------
# User and permissions
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying user and permissions..."

if [ "$(whoami)" = "igou" ]; then
    ok "whoami is igou"
else
    fail "whoami is igou (got $(whoami))"
fi

if [ "$(id -u)" != "0" ]; then
    ok "UID is non-root ($(id -u))"
else
    fail "UID is non-root (got 0)"
fi

if [ "$(stat -c %u /home/igou)" = "$(id -u)" ]; then
    ok "home dir owned by current UID"
else
    fail "home dir owned by current UID (dir=$(stat -c %u /home/igou), user=$(id -u))"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
