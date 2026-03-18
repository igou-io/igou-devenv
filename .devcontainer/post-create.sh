#!/usr/bin/env bash
set -euo pipefail

ARCH=$(dpkg --print-architecture)

# ---------------------------------------------------------------------------
# SSH agent forwarding check
# The devcontainer forwards the host's SSH agent via SSH_AUTH_SOCK.
# This is required for cloning private repos (igou-inventory, etc.)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Python tools via pipx (matches your ansible playbook approach)
# ---------------------------------------------------------------------------
echo "==> Installing pipx and Python tools..."
sudo apt-get update && sudo apt-get install -y --no-install-recommends pipx
sudo rm -rf /var/lib/apt/lists/*

PIPX_PACKAGES=(
    ansible
    ansible-navigator
    ansible-builder
    ansible-rulebook
    ansible-runner
    ansible-lint
    awxkit
    yq
    mkdocs-material
)
for pkg in "${PIPX_PACKAGES[@]}"; do
    echo "    Installing ${pkg}..."
    pipx install "${pkg}" --include-deps || echo "    WARNING: Failed to install ${pkg}"
done

# Inject useful Ansible deps into the ansible venv
pipx inject ansible kubernetes jmespath || true

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
# CLI tools — binary installs
# ---------------------------------------------------------------------------
echo "==> Installing ArgoCD CLI..."
ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
curl -sSL -o /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}"
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd

echo "==> Installing kustomize..."
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

echo "==> Installing kubeseal..."
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name | sed 's/v//')
curl -sSL -o /tmp/kubeseal.tar.gz "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
sudo mv /tmp/kubeseal /usr/local/bin/
rm /tmp/kubeseal.tar.gz

echo "==> Installing flux CLI..."
curl -s https://fluxcd.io/install.sh | bash

echo "==> Installing SOPS..."
SOPS_VERSION=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -sSL -o /tmp/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}"
chmod +x /tmp/sops
sudo mv /tmp/sops /usr/local/bin/sops

echo "==> Installing OpenShift CLI (oc)..."
curl -sSL -o /tmp/oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz
tar -xzf /tmp/oc.tar.gz -C /tmp oc
sudo mv /tmp/oc /usr/local/bin/
rm /tmp/oc.tar.gz

echo "==> Installing virtctl..."
VIRTCTL_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r .tag_name)
curl -sSL -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-${ARCH}"
chmod +x /tmp/virtctl
sudo mv /tmp/virtctl /usr/local/bin/virtctl

echo "==> Installing Claude Code (npm)..."
if command -v npm &> /dev/null; then
    sudo npm install -g @anthropic-ai/claude-code
else
    echo "    npm not found, skipping Claude Code install"
fi

# ---------------------------------------------------------------------------
# Clone repos via SSH (requires agent forwarding)
# ---------------------------------------------------------------------------
echo "==> Cloning igou-io repos into /workspace..."

# Add GitHub to known_hosts to avoid interactive prompts
mkdir -p /home/vscode/.ssh
ssh-keyscan -t ed25519,rsa github.com >> /home/vscode/.ssh/known_hosts 2>/dev/null

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
        "ansible.python.interpreterPath": "/home/vscode/.local/share/pipx/venvs/ansible/bin/python3",
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