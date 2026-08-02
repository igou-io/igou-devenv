# Prerequisites

Everything needed to build, run, and test the igou-devenv development environment.

## Host Operating System

Linux (x86_64). The devcontainer and Claude container are built and tested on Ubuntu-based hosts. Other distributions work as long as all dependencies below are met.

## Container Runtime

The devcontainer is **always launched via privileged Docker** on the host —
Cursor's Dev Containers extension and the `devcontainer` CLI both call `docker`.
Podman is **not** required on the host; it ships *inside* the image for nested
container work (e.g. the `claude-run` / `cursor-run` / `opencode-run` agent
launchers run podman inside the devcontainer).

| Tool | Purpose |
|---|---|
| **Docker** (Engine or Desktop) | Runs the devcontainer; the `devcontainer` CLI and Cursor call `docker` |
| **devcontainer CLI** | Drives the build/up/exec lifecycle (`npm install -g @devcontainers/cli`, or bundled with Cursor/VS Code) |

### Minimum versions

- Docker Engine >= 24, daemon running, your user in the `docker` group
- `devcontainer` CLI (installed via `npm install -g @devcontainers/cli` or bundled with Cursor/VS Code)

### Playbook: Install container runtime (Docker)

```yaml
---
- name: Install container runtime
  hosts: localhost
  connection: local
  become: true
  tasks:
    - name: Install Docker (Debian/Ubuntu)
      ansible.builtin.apt:
        name:
          - docker.io
          - docker-compose-plugin
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Docker (Fedora/RHEL)
      ansible.builtin.dnf:
        name:
          - docker
        state: present
      when: ansible_os_family == "RedHat"

    - name: Enable and start the Docker daemon
      ansible.builtin.systemd:
        name: docker
        enabled: true
        state: started

    - name: Add the current user to the docker group
      ansible.builtin.user:
        name: "{{ ansible_user_id }}"
        groups: docker
        append: true

    - name: Install Node.js for devcontainer CLI (Debian/Ubuntu)
      ansible.builtin.apt:
        name: nodejs
        state: present
      when: ansible_os_family == "Debian"

    - name: Install Node.js for devcontainer CLI (Fedora/RHEL)
      ansible.builtin.dnf:
        name: nodejs
        state: present
      when: ansible_os_family == "RedHat"

    - name: Install devcontainer CLI globally
      community.general.npm:
        name: "@devcontainers/cli"
        global: true
        state: present
```

## SSH

SSH keys are **not** kept on the host or forwarded into the container. The
devcontainer runs its own ssh-agent (started empty by `bin/ensure-ssh-agent`)
and keys are pulled from 1Password on demand with `ssh-use` — see
[adr/0004](../adr/0004-ssh-keys-from-1password.md).

The host only needs:

- `~/.ssh/config` and `~/.ssh/known_hosts` — bind-mounted read-only into the
  container. No private key on disk, no host ssh-agent, no agent forwarding.
- Your SSH keys stored in the 1Password `lab_ssh` vault, resolved in-container
  via the 1Password CLI (see the [1Password CLI](#1password-cli) section below).

Inside the container:

```bash
ssh-use            # load the default key (op://lab_ssh/github)
ssh-use lab-nodes  # load a specific key
ssh-unuse          # drop all loaded keys
```

## 1Password CLI

The environment-switching system (`use`/`unuse`) resolves `op://` secret references at runtime via `op inject`.

- **1Password CLI** (`op`) installed on the host: <https://developer.1password.com/docs/cli/get-started/>
- A **1Password Service Account token** stored at `~/.config/op/service-account-token`, or the `OP_SERVICE_ACCOUNT_TOKEN` environment variable set in your shell.
- A 1Password vault containing the secrets referenced in `envs/*.env` files.

> If you do not use 1Password, the devcontainer still builds and runs — only `use <env>` will fail.

### Playbook: Install 1Password CLI

```yaml
---
- name: Install 1Password CLI
  hosts: localhost
  connection: local
  tasks:
    - name: Add 1Password GPG key (Debian/Ubuntu)
      become: true
      ansible.builtin.shell: |
        curl -sS https://downloads.1password.com/linux/keys/1password.asc \
          | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
      args:
        creates: /usr/share/keyrings/1password-archive-keyring.gpg
      when: ansible_os_family == "Debian"

    - name: Add 1Password apt repo (Debian/Ubuntu)
      become: true
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch={{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          signed-by=/usr/share/keyrings/1password-archive-keyring.gpg]
          https://downloads.1password.com/linux/debian/{{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          stable main
        filename: 1password
        state: present
      when: ansible_os_family == "Debian"

    - name: Install 1Password CLI (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: 1password-cli
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Add 1Password yum repo (Fedora/RHEL)
      become: true
      ansible.builtin.yum_repository:
        name: 1password
        description: 1Password CLI
        baseurl: https://downloads.1password.com/linux/rpm/stable/$basearch
        gpgkey: https://downloads.1password.com/linux/keys/1password.asc
        gpgcheck: true
        repo_gpgcheck: true
      when: ansible_os_family == "RedHat"

    - name: Install 1Password CLI (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: 1password-cli
        state: present
      when: ansible_os_family == "RedHat"

    - name: Create 1Password config directory
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.config/op"
        state: directory
        mode: "0700"

    - name: Verify op is installed
      ansible.builtin.command: op --version
      changed_when: false
```

## Git

- Git >= 2.25 installed on the host.
- `~/.gitconfig` present (even if empty — the init script creates it if missing).

### Playbook: Git setup

```yaml
---
- name: Git setup
  hosts: localhost
  connection: local
  vars:
    git_user_name: ""
    git_user_email: ""
  tasks:
    - name: Install git (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: git
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install git (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: git
        state: present
      when: ansible_os_family == "RedHat"

    - name: Ensure ~/.gitconfig exists
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.gitconfig"
        state: touch
        mode: "0644"
        modification_time: preserve
        access_time: preserve

    - name: Set git user.name
      community.general.git_config:
        scope: global
        name: user.name
        value: "{{ git_user_name }}"
      when: git_user_name | length > 0

    - name: Set git user.email
      community.general.git_config:
        scope: global
        name: user.email
        value: "{{ git_user_email }}"
      when: git_user_email | length > 0

    - name: Configure git to use SSH for GitHub
      community.general.git_config:
        scope: global
        name: "url.git@github.com:.insteadOf"
        value: "https://github.com/"

    - name: Add GitHub to known_hosts
      ansible.builtin.known_hosts:
        name: github.com
        key: "{{ lookup('pipe', 'ssh-keyscan -t ed25519 github.com 2>/dev/null') }}"
        path: "{{ ansible_env.HOME }}/.ssh/known_hosts"
        state: present
```

## GitHub CLI (`gh`)

The `gh` CLI is installed inside the container, but for host-side operations like `make renovate-dry-run` you need:

- A `GITHUB_TOKEN` environment variable with repo scope (only for Renovate dry-run).

### Playbook: GitHub CLI host install

```yaml
---
- name: GitHub CLI host install
  hosts: localhost
  connection: local
  tasks:
    - name: Add GitHub CLI keyring (Debian/Ubuntu)
      become: true
      ansible.builtin.shell: |
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          -o /usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      args:
        creates: /usr/share/keyrings/githubcli-archive-keyring.gpg
      when: ansible_os_family == "Debian"

    - name: Add GitHub CLI apt repo (Debian/Ubuntu)
      become: true
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch={{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg]
          https://cli.github.com/packages stable main
        filename: github-cli
        state: present
      when: ansible_os_family == "Debian"

    - name: Install gh CLI (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: gh
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Add GitHub CLI dnf repo (Fedora/RHEL)
      become: true
      ansible.builtin.yum_repository:
        name: gh-cli
        description: GitHub CLI
        baseurl: https://cli.github.com/packages/rpm
        gpgkey: https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x23F3D4EA75716059
        gpgcheck: true
        repo_gpgcheck: true
      when: ansible_os_family == "RedHat"

    - name: Install gh CLI (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: gh
        state: present
      when: ansible_os_family == "RedHat"

    - name: Check gh auth status
      ansible.builtin.command: gh auth status
      register: gh_auth
      changed_when: false
      failed_when: false

    - name: Prompt to authenticate gh
      ansible.builtin.debug:
        msg: "gh is not authenticated. Run 'gh auth login' to authenticate."
      when: gh_auth.rc != 0
```

## Claude Code

Required for the agent-container workflow (`claude-run`, `cursor-run`, `opencode-run`):

- A valid Claude account with an API key or active session (for `claude-run`).
- `~/.claude/`, `~/.claude.json`, and `~/.claude-container/` on the host (created
  automatically by `init.sh` if missing — `~/.claude-container/` is the per-container
  state directory so the host's Claude install and the containerized one don't share
  the same JSON file).
- The agent-container images live in [`igou-containers`](https://github.com/igou-io/igou-containers)
  and are pulled from GHCR on first launch. No local `make claude-build` step is needed
  — the launcher scripts handle pull-and-run.

### Playbook: Claude Code prerequisites

```yaml
---
- name: Claude Code prerequisites
  hosts: localhost
  connection: local
  tasks:
    - name: Create Claude state directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0755"
      loop:
        - "{{ ansible_env.HOME }}/.claude"
        - "{{ ansible_env.HOME }}/.claude-container"

    - name: Ensure ~/.claude.json exists
      ansible.builtin.copy:
        content: "{}"
        dest: "{{ ansible_env.HOME }}/.claude.json"
        force: false
        mode: "0644"

    - name: Install Claude Code native binary
      ansible.builtin.shell: curl -fsSL https://claude.ai/install.sh | bash
      args:
        creates: "{{ ansible_env.HOME }}/.local/bin/claude"

    - name: Verify Claude Code is installed
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/claude --version"
      changed_when: false
```

## Host Directories

The `init.sh` script creates these automatically on first run, but they are worth knowing about since they are bind-mounted into the container:

| Path | Purpose | Mount mode |
|---|---|---|
| `~/.ssh` | SSH keys and config | read-only |
| `~/.gitconfig` | Git configuration | read-only |
| `~/.kube` | Kubernetes configs | read-write |
| `~/.config/op` | 1Password CLI config | read-only |
| `~/.config/argocd` | ArgoCD CLI config | read-write |
| `~/.terraform.d` | Terraform plugin cache | read-write |
| `~/.claude` | Claude Code state | read-write |
| `~/.claude.json` | Claude Code auth | read-write |
| `~/.claude-container` | Claude container state | read-write |
| `~/workspace` | Shared workspace root | read-write |
| `~/rosa-gitops` | ROSA GitOps repo | read-write |
| `~/rosa-gitops-example-team` | ROSA GitOps example team repo | read-write |

### Playbook: Create host directories

```yaml
---
- name: Create host directories for bind mounts
  hosts: localhost
  connection: local
  tasks:
    - name: Create required directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0755"
      loop:
        - "{{ ansible_env.HOME }}/.ssh"
        - "{{ ansible_env.HOME }}/.kube"
        - "{{ ansible_env.HOME }}/.config/op"
        - "{{ ansible_env.HOME }}/.config/argocd"
        - "{{ ansible_env.HOME }}/.terraform.d"
        - "{{ ansible_env.HOME }}/.claude"
        - "{{ ansible_env.HOME }}/.claude-container"
        - "{{ ansible_env.HOME }}/workspace"
        - "{{ ansible_env.HOME }}/rosa-gitops"
        - "{{ ansible_env.HOME }}/rosa-gitops-example-team"

    - name: Set restrictive permissions on sensitive directories
      ansible.builtin.file:
        path: "{{ item }}"
        mode: "0700"
      loop:
        - "{{ ansible_env.HOME }}/.ssh"
        - "{{ ansible_env.HOME }}/.config/op"

    - name: Ensure ~/.gitconfig file exists
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.gitconfig"
        state: touch
        mode: "0644"
        modification_time: preserve
        access_time: preserve

    - name: Ensure ~/.claude.json file exists
      ansible.builtin.copy:
        content: "{}"
        dest: "{{ ansible_env.HOME }}/.claude.json"
        force: false
        mode: "0644"
```

## Hardware

- **Disk**: ~10 GB free for container images (devcontainer + Claude container).
- **Memory**: 4 GB minimum (the Claude container is capped at 4 GB by default).
- **CPU**: No strict minimum; the Claude container is limited to 2 CPUs.

---

## All-in-One Playbook

Run every prerequisite section in a single pass. Combine the per-section playbooks above into one file and run:

```bash
ansible-playbook doc/prerequisites.md  # won't work — extract the YAML blocks
# or save as a standalone file:
ansible-playbook prereqs.yml -K        # -K prompts for sudo password
```

```yaml
---
- name: igou-devenv full prerequisite setup
  hosts: localhost
  connection: local
  vars:
    git_user_name: ""
    git_user_email: ""
    ssh_key_path: "{{ ansible_env.HOME }}/.ssh/id_ed25519"
    ssh_key_comment: "{{ ansible_user_id }}@{{ ansible_hostname }}"
    subuid_start: 100000
    subuid_count: 65536
    user_namespaces_max: 28633
  tasks:
    # ==================================================================
    # Container Runtime
    # ==================================================================
    - name: Install Docker (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name:
          - docker.io
          - docker-compose-plugin
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Docker (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name:
          - docker
        state: present
      when: ansible_os_family == "RedHat"

    - name: Enable and start the Docker daemon
      become: true
      ansible.builtin.systemd:
        name: docker
        enabled: true
        state: started

    - name: Add the current user to the docker group
      become: true
      ansible.builtin.user:
        name: "{{ ansible_user_id }}"
        groups: docker
        append: true

    - name: Install Node.js (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: nodejs
        state: present
      when: ansible_os_family == "Debian"

    - name: Install Node.js (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: nodejs
        state: present
      when: ansible_os_family == "RedHat"

    - name: Install devcontainer CLI
      community.general.npm:
        name: "@devcontainers/cli"
        global: true
        state: present

    # ==================================================================
    # Git
    # ==================================================================
    - name: Install git (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: git
        state: present
      when: ansible_os_family == "Debian"

    - name: Install git (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: git
        state: present
      when: ansible_os_family == "RedHat"

    - name: Configure git user.name
      community.general.git_config:
        scope: global
        name: user.name
        value: "{{ git_user_name }}"
      when: git_user_name | length > 0

    - name: Configure git user.email
      community.general.git_config:
        scope: global
        name: user.email
        value: "{{ git_user_email }}"
      when: git_user_email | length > 0

    - name: Configure git SSH for GitHub
      community.general.git_config:
        scope: global
        name: "url.git@github.com:.insteadOf"
        value: "https://github.com/"

    # ==================================================================
    # SSH
    # ==================================================================
    - name: Ensure ~/.ssh directory exists
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.ssh"
        state: directory
        mode: "0700"

    - name: Generate ed25519 SSH key pair
      community.crypto.openssh_keypair:
        path: "{{ ssh_key_path }}"
        type: ed25519
        comment: "{{ ssh_key_comment }}"
      register: ssh_key

    - name: Add GitHub to known_hosts
      ansible.builtin.known_hosts:
        name: github.com
        key: "{{ lookup('pipe', 'ssh-keyscan -t ed25519 github.com 2>/dev/null') }}"
        path: "{{ ansible_env.HOME }}/.ssh/known_hosts"
        state: present

    - name: Show public key for GitHub registration
      ansible.builtin.debug:
        msg: >-
          Add this public key to GitHub (Settings → SSH and GPG keys):
          {{ lookup('file', ssh_key_path + '.pub') }}
      when: ssh_key.changed

    # ==================================================================
    # 1Password CLI
    # ==================================================================
    - name: Add 1Password GPG key (Debian/Ubuntu)
      become: true
      ansible.builtin.shell: |
        curl -sS https://downloads.1password.com/linux/keys/1password.asc \
          | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
      args:
        creates: /usr/share/keyrings/1password-archive-keyring.gpg
      when: ansible_os_family == "Debian"

    - name: Add 1Password apt repo (Debian/Ubuntu)
      become: true
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch={{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          signed-by=/usr/share/keyrings/1password-archive-keyring.gpg]
          https://downloads.1password.com/linux/debian/{{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          stable main
        filename: 1password
        state: present
      when: ansible_os_family == "Debian"

    - name: Install 1Password CLI (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: 1password-cli
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Add 1Password yum repo (Fedora/RHEL)
      become: true
      ansible.builtin.yum_repository:
        name: 1password
        description: 1Password CLI
        baseurl: https://downloads.1password.com/linux/rpm/stable/$basearch
        gpgkey: https://downloads.1password.com/linux/keys/1password.asc
        gpgcheck: true
        repo_gpgcheck: true
      when: ansible_os_family == "RedHat"

    - name: Install 1Password CLI (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: 1password-cli
        state: present
      when: ansible_os_family == "RedHat"

    - name: Create 1Password config directory
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.config/op"
        state: directory
        mode: "0700"

    # ==================================================================
    # GitHub CLI
    # ==================================================================
    - name: Add GitHub CLI keyring (Debian/Ubuntu)
      become: true
      ansible.builtin.shell: |
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          -o /usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      args:
        creates: /usr/share/keyrings/githubcli-archive-keyring.gpg
      when: ansible_os_family == "Debian"

    - name: Add GitHub CLI apt repo (Debian/Ubuntu)
      become: true
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch={{ ansible_architecture | regex_replace('x86_64', 'amd64') }}
          signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg]
          https://cli.github.com/packages stable main
        filename: github-cli
        state: present
      when: ansible_os_family == "Debian"

    - name: Install gh CLI (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name: gh
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Add GitHub CLI dnf repo (Fedora/RHEL)
      become: true
      ansible.builtin.yum_repository:
        name: gh-cli
        description: GitHub CLI
        baseurl: https://cli.github.com/packages/rpm
        gpgkey: https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x23F3D4EA75716059
        gpgcheck: true
        repo_gpgcheck: true
      when: ansible_os_family == "RedHat"

    - name: Install gh CLI (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name: gh
        state: present
      when: ansible_os_family == "RedHat"

    # ==================================================================
    # Host directories and files (mirrors init.sh)
    # ==================================================================
    - name: Create bind-mount directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0755"
      loop:
        - "{{ ansible_env.HOME }}/.kube"
        - "{{ ansible_env.HOME }}/.config/argocd"
        - "{{ ansible_env.HOME }}/.terraform.d"
        - "{{ ansible_env.HOME }}/.claude"
        - "{{ ansible_env.HOME }}/.claude-container"
        - "{{ ansible_env.HOME }}/workspace"
        - "{{ ansible_env.HOME }}/rosa-gitops"
        - "{{ ansible_env.HOME }}/rosa-gitops-example-team"

    - name: Ensure ~/.gitconfig exists
      ansible.builtin.file:
        path: "{{ ansible_env.HOME }}/.gitconfig"
        state: touch
        mode: "0644"
        modification_time: preserve
        access_time: preserve

    - name: Ensure ~/.claude.json exists
      ansible.builtin.copy:
        content: "{}"
        dest: "{{ ansible_env.HOME }}/.claude.json"
        force: false
        mode: "0644"

    # ==================================================================
    # Claude Code
    # ==================================================================
    - name: Install Claude Code native binary
      ansible.builtin.shell: curl -fsSL https://claude.ai/install.sh | bash
      args:
        creates: "{{ ansible_env.HOME }}/.local/bin/claude"
```
