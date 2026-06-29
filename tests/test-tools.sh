#!/usr/bin/env bash
# Verify installed tools, user config, and Python packages.
# Runs inside the devcontainer — used by both `make test-tools` and CI.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# CLI tools — verify they execute, not just exist on PATH
# ---------------------------------------------------------------------------
echo "==> Verifying CLI tools..."

declare -A TOOLS=(
    [python3]="python3 --version"
    [claude]="claude --version"
    [opencode]="opencode --version"
    [codex]="codex --version"
    [agent]="agent --version"
    [ansible]="ansible --version"
    [bwrap]="bwrap --version"
    [op]="op --version"
    [podman]="podman --version"
    [buildah]="buildah --version"
    [skopeo]="skopeo --version"
    [rg]="rg --version"
    [jq]="jq --version"
    [shellcheck]="shellcheck --version"
    [yamllint]="yamllint --version"
    [nmap]="nmap --version"
    [dig]="dig -v"
    [vim]="vim --version"
    [tmux]="tmux -V"
    [htop]="htop --version"
    [make]="make --version"
    [unshare]="unshare --version"
    [ps]="ps --version"
    [qemu-system-x86_64]="qemu-system-x86_64 --version"
    [qemu-img]="qemu-img --version"
    [virsh]="virsh --version"
    [virtqemud]="virtqemud --version"
)

for tool in $(echo "${!TOOLS[@]}" | tr ' ' '\n' | sort); do
    version=$(${TOOLS[$tool]} 2>&1 | head -1 || true)
    if [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool"
    fi
done

# ---------------------------------------------------------------------------
# Python packages
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying Python packages..."

PIP_PACKAGES=(
    ansible-core
    ansible-navigator
    ansible-builder
    ansible-lint
    ansible-runner
    yq
    kubernetes
    jmespath
)

for pkg in "${PIP_PACKAGES[@]}"; do
    if pip show "$pkg" &>/dev/null; then
        ok "pip: $pkg"
    else
        fail "pip: $pkg"
    fi
done

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

if sudo -n true 2>/dev/null; then
    ok "passwordless sudo"
else
    fail "passwordless sudo"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
