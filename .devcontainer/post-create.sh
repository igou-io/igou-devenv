#!/usr/bin/env bash
set -euo pipefail

ARCH=$(dpkg --print-architecture)

# ---------------------------------------------------------------------------
# SSH agent forwarding check
# The devcontainer forwards the host's SSH agent via SSH_AUTH_SOCK.
# This is required for cloning private repos (igou-inventory, etc.)
# ---------------------------------------------------------------------------
if [ -z "${CI:-}" ]; then
    echo "==> Checking SSH agent forwarding..."
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        echo "    SSH_AUTH_SOCK is set: ${SSH_AUTH_SOCK}"
        ssh-add -l 2>/dev/null && echo "    Agent has keys loaded" || echo "    WARNING: Agent is reachable but has no keys"
    else
        echo "    WARNING: SSH_AUTH_SOCK is not set. Private repo clones will fail."
        echo "    Make sure your SSH agent is running and Cursor is forwarding it."
    fi

    # Always use SSH for GitHub so forwarded keys work
    git config --global url."git@github.com:".insteadOf "https://github.com/"
else
    echo "==> CI detected, skipping SSH agent check"
fi

# ---------------------------------------------------------------------------
# Python tools (versions pinned in requirements.txt for Renovate tracking)
# ---------------------------------------------------------------------------
echo "==> Installing Python tools..."
pip install --break-system-packages -r "$(dirname "$0")/requirements.txt"

# ---------------------------------------------------------------------------
# 1Password CLI
# ---------------------------------------------------------------------------
echo "==> Installing 1Password CLI..."
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${ARCH} stable main" | \
    sudo tee /etc/apt/sources.list.d/1password.list
sudo apt-get update && sudo apt-get install -y 1password-cli
sudo rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# CLI tools — pinned versions managed by Renovate
# ---------------------------------------------------------------------------

# renovate: datasource=github-releases depName=argoproj/argo-cd
ARGOCD_VERSION="v3.3.0"
echo "==> Installing ArgoCD CLI ${ARGOCD_VERSION}..."
curl -sSL -o /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}"
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd

# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/(?<version>.*)$
KUSTOMIZE_VERSION="v5.8.1"
echo "==> Installing kustomize ${KUSTOMIZE_VERSION}..."
curl -sSL -o /tmp/kustomize.tar.gz "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
tar -xzf /tmp/kustomize.tar.gz -C /tmp kustomize
sudo mv /tmp/kustomize /usr/local/bin/
rm /tmp/kustomize.tar.gz

# renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
KUBESEAL_VERSION="v0.36.1"
echo "==> Installing kubeseal ${KUBESEAL_VERSION}..."
KUBESEAL_VERSION_BARE="${KUBESEAL_VERSION#v}"
curl -sSL -o /tmp/kubeseal.tar.gz "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION_BARE}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
sudo mv /tmp/kubeseal /usr/local/bin/
rm /tmp/kubeseal.tar.gz

# renovate: datasource=github-releases depName=fluxcd/flux2
FLUX_VERSION="v2.8.3"
echo "==> Installing flux CLI ${FLUX_VERSION}..."
curl -sSL -o /tmp/flux.tar.gz "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/flux_${FLUX_VERSION#v}_linux_${ARCH}.tar.gz"
tar -xzf /tmp/flux.tar.gz -C /tmp flux
sudo mv /tmp/flux /usr/local/bin/
rm /tmp/flux.tar.gz

# renovate: datasource=github-releases depName=getsops/sops
SOPS_VERSION="v3.12.2"
echo "==> Installing SOPS ${SOPS_VERSION}..."
curl -sSL -o /tmp/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}"
chmod +x /tmp/sops
sudo mv /tmp/sops /usr/local/bin/sops

echo "==> Installing OpenShift CLI (oc)..."
curl -sSL -o /tmp/oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz
tar -xzf /tmp/oc.tar.gz -C /tmp oc
sudo mv /tmp/oc /usr/local/bin/
rm /tmp/oc.tar.gz

# renovate: datasource=github-releases depName=kubevirt/kubevirt
VIRTCTL_VERSION="v1.7.2"
echo "==> Installing virtctl ${VIRTCTL_VERSION}..."
curl -sSL -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-${ARCH}"
chmod +x /tmp/virtctl
sudo mv /tmp/virtctl /usr/local/bin/virtctl

# ---------------------------------------------------------------------------
# Clone repos via SSH (requires agent forwarding) — skipped in CI
# ---------------------------------------------------------------------------
if [ -z "${CI:-}" ]; then
    echo "==> Cloning igou-io repos into /workspace..."

    # Add GitHub to global known_hosts to avoid interactive prompts.
    # ~/.ssh is bind-mounted read-only, so write to the system-wide file instead.
    ssh-keyscan -t ed25519,rsa github.com 2>/dev/null | sudo tee -a /etc/ssh/ssh_known_hosts > /dev/null

    REPOS=(
        "igou-io/igou-kubernetes"
        "igou-io/igou-ansible"
        "igou-io/igou-infrastructure"
        "igou-io/igou-openshift"
        "igou-io/igou-containers"
        # Private repos — require SSH agent forwarding
        "igou-io/igou-inventory"
        "igou-io/igou-kubernetes-private"
    )
    for repo in "${REPOS[@]}"; do
        name=$(basename "$repo")
        if [ ! -d "/workspace/${name}" ]; then
            echo "    Cloning ${repo}..."
            git clone "git@github.com:${repo}.git" "/workspace/${name}" || echo "    WARNING: Failed to clone ${repo} (is your SSH key forwarded?)"
        else
            echo "    ${name} already exists, skipping"
        fi
    done
else
    echo "==> CI detected, skipping repo cloning"
fi

# ---------------------------------------------------------------------------
# Shell configuration (mirrors your ansible playbook's bashrc setup)
# ---------------------------------------------------------------------------
echo "==> Configuring shell..."

cat >> /home/vscode/.bashrc << 'BASHRC'

# --- igou-io devenv config ---
export ANSIBLE_INVENTORY=/workspace/igou-inventory
export ANSIBLE_HOST_KEY_CHECKING=False
export PATH=$PATH:/home/vscode/.local/bin:/home/vscode/bin

# Aliases
alias k=kubectl

# direnv
eval "$(direnv hook bash)"
BASHRC

# ---------------------------------------------------------------------------
# Workspace file for Cursor multi-root workspace
# ---------------------------------------------------------------------------
echo "==> Writing workspace file..."
cat > /workspace/homelab.code-workspace << 'EOF'
{
    "folders": [
        { "path": "igou-ansible" },
        { "path": "igou-inventory" },
        { "path": "igou-kubernetes" },
        { "path": "igou-kubernetes-private" },
        { "path": "igou-infrastructure" },
        { "path": "igou-openshift" },
        { "path": "igou-containers" }
    ],
    "settings": {
        "ansible.python.interpreterPath": "/usr/local/python/current/bin/python3",
        "files.trimTrailingWhitespace": true,
        "files.associations": {
            "**/group_vars/**/*": "jinja-yaml",
            "**/host_vars/**/*": "jinja-yaml",
            "**/roles/**/*.yml": "ansible",
            "**/playbooks/**/*.yml": "ansible",
            "**/roles/**/*.yaml": "ansible",
            "**/playbooks/**/*.yaml": "ansible",
            "ansible.cfg": "ini",
            "**/*.yaml": "yaml",
            "**/*.yml": "yaml"
        },
        "yaml.schemas": {
            "kubernetes": [
                "igou-kubernetes/apps/**/*.yaml",
                "igou-kubernetes/base/**/*.yaml",
                "igou-kubernetes/bootstrap/**/*.yaml",
                "igou-kubernetes/config/**/*.yaml"
            ],
            "https://squidfunk.github.io/mkdocs-material/schema.json": "mkdocs.yml"
        }
    }
}
EOF

echo "==> Setup complete!"