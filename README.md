# igou-io devenv

Reproducible development environment for homelab infrastructure work.
Podman-native, Cursor as the IDE, SSH agent forwarding for private repos.

## What's Inside

**Languages & Runtimes:** Go, Python 3.12, Node.js (for Claude Code)

**Kubernetes:** kubectl, helm, kustomize, ArgoCD CLI, kubeseal, flux, virtctl

**Infrastructure:** Terraform, tflint, SOPS, age

**Ansible (via pipx):** ansible, ansible-navigator, ansible-builder,
ansible-rulebook, ansible-runner, ansible-lint, awxkit

**OpenShift:** oc CLI

**Container Tooling:** podman, buildah, skopeo (installed in container), plus
Docker CLI (for compatibility — talks to host podman via socket)

**General:** 1Password CLI, GitHub CLI, jq, yq, direnv, shellcheck, make,
tree, p7zip, mkdocs-material

**AI:** Claude Code (`claude` CLI)

## Quick Start

### Prerequisites (on the host)

1. **Podman** installed and running rootless
2. **Podman socket** enabled:
   ```bash
   systemctl --user enable --now podman.socket
   ls $XDG_RUNTIME_DIR/podman/podman.sock
   ```
3. **Docker CLI symlink** — Cursor's devcontainer extension calls `docker`
   under the hood even when configured for podman:
   ```bash
   # Fedora/RHEL:
   sudo dnf install -y podman-docker
   # Ubuntu/Debian:
   sudo apt install -y podman-docker
   ```
4. **SSH agent running with your key loaded** — required for cloning private
   repos (igou-inventory, igou-kubernetes-private):
   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519   # or whichever key has GitHub access
   # Verify:
   ssh -T git@github.com
   ```
   The devcontainer bind-mounts your `SSH_AUTH_SOCK` into the container, so
   the forwarded agent is available for git operations inside the container.
5. **Cursor** with the **Cursor Dev Containers** extension (`anysphere.remote-containers`).
6. **Cursor setting** to use podman — in Settings, set `dev.containers.dockerPath`
   to `podman`.
7. Your credentials in the standard locations:
   - `~/.ssh/` — SSH keys and config
   - `~/.kube/` — Kubernetes configs
   - `~/.config/argocd/` — ArgoCD CLI config (create if missing: `mkdir -p ~/.config/argocd`)
   - `~/.terraform.d/` — Terraform plugin cache/credentials

### Open the Environment

```bash
git clone https://github.com/igou-io/devenv.git ~/devenv
cd ~/devenv
cursor .
```

Or from the command palette (Ctrl+Shift+P): **Dev Containers: Reopen in Container**

### After First Build

The `post-create.sh` script automatically:
- Verifies SSH agent forwarding is working
- Installs all CLI tools and Python packages via pipx
- Installs 1Password CLI
- Clones all igou-io repos (public and private) into `/workspace/`
- Configures bashrc with exports and aliases
- Creates a `homelab.code-workspace` file

Your repos will be at:
```
/workspace/
├── igou-ansible/
├── igou-containers/
├── igou-infrastructure/
├── igou-inventory/          (private)
├── igou-kubernetes/
├── igou-kubernetes-private/ (private)
├── igou-openshift/
└── homelab.code-workspace
```

Open the workspace via **File > Open Workspace from File** → `/workspace/homelab.code-workspace`

## How SSH Agent Forwarding Works

Your local machine runs an SSH agent with your GitHub key. When you SSH into
the mini PC (or when Cursor connects via Remote SSH), the agent is forwarded
to the remote host. The devcontainer then bind-mounts the `SSH_AUTH_SOCK`
from the host into the container at `/tmp/ssh-agent.sock` and sets the
`SSH_AUTH_SOCK` environment variable to point there.

This means `git clone git@github.com:igou-io/igou-inventory.git` works inside
the container using your local machine's key, without the key ever being
copied to the remote host or into the container.

**For this chain to work, ensure:**
1. Your local machine has `ssh-agent` running with your key
2. Your SSH config for the remote host has `ForwardAgent yes`
3. The host's `sshd_config` has `AllowAgentForwarding yes` (default on most distros)

## How Podman Integration Works

The devcontainer mounts the host's podman socket at `/var/run/docker.sock` inside
the container. This means:

- `docker build`, `docker push`, etc. work via the Docker CLI — they talk to
  podman on the host through the socket
- `podman build`, `buildah bud`, `skopeo copy` also work natively
- No daemon runs inside the container
- `--userns=keep-id` ensures your host UID maps correctly into the container

## Using Claude Code

```bash
cd /workspace/igou-kubernetes
claude

# Or one-off commands
claude "explain what this ArgoCD ApplicationSet does"
claude "add a new app for cert-manager to the apps/ directory"
```

Running Claude Code inside the devcontainer is a good fit — it gets full access
to your toolchain in an isolated environment, and you can run it with
`--dangerously-skip-permissions` more comfortably knowing the blast radius is
limited to the container.

## Reprovisioning the Host

When you reprovision your mini PC, you need:

1. Podman (rootless) + socket enabled + podman-docker
2. SSH server (with agent forwarding allowed)
3. Cursor installed
4. Your credentials (`~/.ssh`, `~/.kube`, etc.)
5. This repo cloned

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fedora/RHEL
sudo dnf install -y podman podman-docker openssh-server
systemctl --user enable --now podman.socket
loginctl enable-linger $USER

# Ensure SSH agent forwarding is allowed
grep -q "AllowAgentForwarding yes" /etc/ssh/sshd_config || \
    echo "AllowAgentForwarding yes" | sudo tee -a /etc/ssh/sshd_config

mkdir -p ~/.ssh ~/.kube ~/.config/argocd ~/.terraform.d

echo "Host ready. Clone devenv and open with: cursor ~/devenv"
```

## Customization

### Adding Tools

- **apt packages** → add to `Dockerfile`
- **Devcontainer Features** → add to `devcontainer.json` `features` block
- **pip/pipx packages** → add to `post-create.sh`
- **Cursor extensions** → add to `customizations.vscode.extensions` in `devcontainer.json`

### 1Password Integration

The 1Password CLI is installed in the container. For workflows that use
`op run` or `op inject` (like the `1p-envs/ocp.env` pattern from your
ansible playbook), you'll need to authenticate inside the container:
```bash
eval $(op signin)
```

For the Ansible vault password via 1Password:
```bash
export ANSIBLE_VAULT_PASSWORD_FILE=/workspace/igou-ansible/.vaultpassword.sh
```

### Secrets Management

Credentials are bind-mounted from the host. SSH keys are read-only; kubeconfig
is read-write for context switching. The container never stores secrets in its
image layers.

For SOPS/age, mount your age key:
```jsonc
// Add to mounts in devcontainer.json
"source=${localEnv:HOME}/.config/sops/age,target=/home/vscode/.config/sops/age,type=bind,readonly"
```

## Troubleshooting

### SSH Agent Forwarding

**Private repo clone fails with "Permission denied (publickey)":**
```bash
# Inside the container, check if the agent is reachable:
ssh-add -l
# If "Could not open a connection to your authentication agent":
echo $SSH_AUTH_SOCK
ls -la /tmp/ssh-agent.sock
```
If the socket file doesn't exist, the agent wasn't forwarded. Check that:
- Your local `ssh-agent` is running and has keys (`ssh-add -l` locally)
- Your SSH config for the host has `ForwardAgent yes`
- You started Cursor *after* starting the agent

### Podman

**Socket not found:**
```bash
systemctl --user status podman.socket
export XDG_RUNTIME_DIR=/run/user/$(id -u)
loginctl enable-linger $USER
```

**Permission denied on bind mounts:** The `--userns=keep-id` runArg should
handle this. Verify subuid/subgid: `cat /etc/subuid /etc/subgid`

**SELinux denials:** The `--security-opt label=disable` runArg disables SELinux
labeling. To keep SELinux enforcing, use `:Z` suffixes on bind mounts instead.

### Cursor + Devcontainers

**"Reopen in Container" not appearing:** Open command palette (Ctrl+Shift+P) →
`Dev Containers: Reopen in Container`

**Extension calls `docker` despite `dockerPath` setting:** This is a known bug.
The `podman-docker` package works around it.

**Extensions missing after connecting:** Rebuild the container via command
palette → **Dev Containers: Rebuild Container**.