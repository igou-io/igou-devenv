# Prerequisites

Everything needed to build, run, and test the igou-devenv development environment.

## Host Operating System

Linux (x86_64). The devcontainer and Claude container are built and tested on Ubuntu-based hosts. Other distributions work as long as all dependencies below are met.

## Container Runtime

The devcontainer lifecycle requires **both** a Docker-compatible CLI and Podman:

| Tool | Purpose | Why both? |
|---|---|---|
| **Docker CE** (or Docker Desktop) | Cursor/VS Code `devcontainer` CLI calls `docker` internally | Required by the editor extension |
| **podman-docker** (package) | Provides a `docker` CLI shim that delegates to Podman | Satisfies the `docker` calls when Docker CE is not installed |
| **Podman** | Builds/runs the Claude container (`make claude-build`, `claude-run`) | Used directly by Makefile targets and `bin/claude-run` |

Pick **one** of these setups:

- Docker CE installed **and** Podman installed (for Claude container targets).
- Podman installed **with** the `podman-docker` package (provides the `docker` shim so the devcontainer CLI works).

### Minimum versions

- Docker CE >= 24 or Podman >= 4.0
- `devcontainer` CLI (installed via `npm install -g @devcontainers/cli` or bundled with Cursor/VS Code)

### Playbook: Install container runtime (Podman + Docker shim)

```yaml
---
- name: Install container runtime
  hosts: localhost
  connection: local
  become: true
  tasks:
    - name: Install Podman and Docker shim (Debian/Ubuntu)
      ansible.builtin.apt:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - uidmap
          - catatonit
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Podman and Docker shim (Fedora/RHEL)
      ansible.builtin.dnf:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - shadow-utils
          - catatonit
        state: present
      when: ansible_os_family == "RedHat"

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

- **SSH key pair** registered with GitHub (ed25519 or RSA).
- **SSH agent** running on the host with the key loaded (`ssh-add`).
- The Makefile dynamically bind-mounts `$SSH_AUTH_SOCK` into the container. If the socket does not exist, the mount is skipped gracefully.

### Playbook: SSH key and agent setup

```yaml
---
- name: SSH key and agent setup
  hosts: localhost
  connection: local
  vars:
    ssh_key_path: "{{ ansible_env.HOME }}/.ssh/id_ed25519"
    ssh_key_comment: "{{ ansible_user_id }}@{{ ansible_hostname }}"
  tasks:
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

    - name: Ensure SSH agent is running
      ansible.builtin.shell: |
        eval "$(ssh-agent -s)"
        echo "$SSH_AUTH_SOCK"
      args:
        executable: /bin/bash
      environment:
        SSH_AUTH_SOCK: "{{ ansible_env.SSH_AUTH_SOCK | default('') }}"
      register: ssh_agent
      changed_when: false
      when: ansible_env.SSH_AUTH_SOCK is not defined or ansible_env.SSH_AUTH_SOCK == ""

    - name: Add key to SSH agent
      ansible.builtin.shell: ssh-add {{ ssh_key_path }}
      args:
        executable: /bin/bash
      changed_when: false

    - name: Show public key for GitHub registration
      ansible.builtin.debug:
        msg: >-
          Add this public key to GitHub (Settings → SSH and GPG keys):
          {{ lookup('file', ssh_key_path + '.pub') }}
      when: ssh_key.changed
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

Required for the Claude container workflow:

- A valid Claude account with an API key or active session.
- `~/.claude/` and `~/.claude.json` on the host (created automatically by `init.sh` if missing).
- The Claude container image built via `make claude-build` before running `claude-run`.

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

## Podman-Specific Setup

If you are running with Podman as your only container runtime (no Docker CE), follow these additional steps.

### Install Podman and the Docker Shim

The `podman-docker` package installs a `/usr/bin/docker` symlink (or wrapper script) that translates Docker CLI calls to Podman. This is required because the `devcontainer` CLI invokes `docker` directly.

### Enable the Podman Socket

The devcontainer expects a Docker-compatible socket at `/var/run/docker.sock`. Podman provides one via a systemd user service.

Alternatively, set `DOCKER_HOST` so the CLI finds the socket without a symlink:

```bash
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock
```

### Rootless Podman Kernel Requirements

The devcontainer runs with `--privileged` and mounts `/dev/fuse` and `/dev/net/tun`. For rootless Podman:

- **User namespaces** must be enabled: check `sysctl user.max_user_namespaces` (should be > 0).
- **fuse-overlayfs** must be installed for the overlay storage driver.
- **slirp4netns** (or **pasta**) must be installed for rootless networking.
- Subuid/subgid ranges must be configured for your user.

### Podman and the Claude Container

The Claude container (`make claude-build`, `claude-run`) uses Podman directly — no Docker shim needed. Key flags used by `claude-run`:

- `--userns=keep-id` — maps your host UID into the container (rootless).
- `--cap-drop=ALL` — drops all Linux capabilities for security.
- `--tmpfs /tmp:rw,noexec,nosuid,size=256m` — hardened tmpfs mount.
- `--init` — requires `catatonit` on the host (Podman's default init process).

### Network Mode

The devcontainer uses `--network=host` for full host network access. This works out of the box with rootless Podman on Linux. On systems with restricted network namespaces, you may need to lower `net.ipv4.ip_unprivileged_port_start`.

### Playbook: Full Podman-only setup

```yaml
---
- name: Full Podman-only setup
  hosts: localhost
  connection: local
  vars:
    subuid_start: 100000
    subuid_count: 65536
    user_namespaces_max: 28633
  tasks:
    # ----- Package installation -----
    - name: Install Podman stack (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - uidmap
          - catatonit
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Podman stack (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - shadow-utils
          - catatonit
        state: present
      when: ansible_os_family == "RedHat"

    # ----- Kernel tuning -----
    - name: Enable user namespaces
      become: true
      ansible.posix.sysctl:
        name: user.max_user_namespaces
        value: "{{ user_namespaces_max }}"
        sysctl_set: true
        state: present
        reload: true

    - name: Allow unprivileged port binding (for --network=host)
      become: true
      ansible.posix.sysctl:
        name: net.ipv4.ip_unprivileged_port_start
        value: "0"
        sysctl_set: true
        state: present
        reload: true

    # ----- Subuid / subgid -----
    - name: Check subuid entry
      ansible.builtin.command: "grep ^{{ ansible_user_id }}: /etc/subuid"
      register: subuid_check
      changed_when: false
      failed_when: false

    - name: Configure subuid range
      become: true
      ansible.builtin.command: >-
        usermod --add-subuids {{ subuid_start }}-{{ subuid_start + subuid_count - 1 }}
        {{ ansible_user_id }}
      when: subuid_check.rc != 0

    - name: Check subgid entry
      ansible.builtin.command: "grep ^{{ ansible_user_id }}: /etc/subgid"
      register: subgid_check
      changed_when: false
      failed_when: false

    - name: Configure subgid range
      become: true
      ansible.builtin.command: >-
        usermod --add-subgids {{ subuid_start }}-{{ subuid_start + subuid_count - 1 }}
        {{ ansible_user_id }}
      when: subgid_check.rc != 0

    # ----- Podman socket (Docker-compatible API) -----
    - name: Enable podman socket for current user
      ansible.builtin.systemd:
        name: podman.socket
        scope: user
        enabled: true
        state: started

    - name: Symlink podman socket to /var/run/docker.sock
      become: true
      ansible.builtin.file:
        src: "/run/user/{{ ansible_user_uid }}/podman/podman.sock"
        dest: /var/run/docker.sock
        state: link
        force: true

    # ----- Storage driver validation -----
    - name: Check podman storage driver
      ansible.builtin.command: podman info --format {{ '{{.Store.GraphDriverName}}' }}
      register: podman_driver
      changed_when: false

    - name: Warn if storage driver is not overlay
      ansible.builtin.debug:
        msg: >-
          Podman is using '{{ podman_driver.stdout }}' storage driver instead of 'overlay'.
          Install fuse-overlayfs and run 'podman system reset' to switch.
      when: podman_driver.stdout != "overlay"

    # ----- catatonit validation -----
    - name: Check catatonit is available
      ansible.builtin.stat:
        path: /usr/libexec/podman/catatonit
      register: catatonit_libexec

    - name: Check catatonit in PATH
      ansible.builtin.command: command -v catatonit
      register: catatonit_path
      changed_when: false
      failed_when: false
      when: not catatonit_libexec.stat.exists

    - name: Warn if catatonit is missing
      ansible.builtin.debug:
        msg: >-
          catatonit not found. The --init flag used by claude-run will be skipped.
          Install it with your package manager.
      when: not catatonit_libexec.stat.exists and catatonit_path.rc != 0

    # ----- Smoke test -----
    - name: Podman smoke test
      ansible.builtin.command: podman run --rm docker.io/library/alpine echo "podman works"
      changed_when: false

    - name: Docker shim smoke test
      ansible.builtin.command: docker run --rm docker.io/library/alpine echo "docker shim works"
      changed_when: false
```

### Quick Validation

After running the playbook, verify everything works:

```bash
podman info
podman run --rm docker.io/library/alpine echo "podman works"
docker info
docker run --rm alpine echo "docker shim works"
make build
make claude-build
make claude-test
```

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
    - name: Install Podman stack (Debian/Ubuntu)
      become: true
      ansible.builtin.apt:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - uidmap
          - catatonit
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Podman stack (Fedora/RHEL)
      become: true
      ansible.builtin.dnf:
        name:
          - podman
          - podman-docker
          - buildah
          - skopeo
          - fuse-overlayfs
          - slirp4netns
          - shadow-utils
          - catatonit
        state: present
      when: ansible_os_family == "RedHat"

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
    # Podman rootless configuration
    # ==================================================================
    - name: Enable user namespaces
      become: true
      ansible.posix.sysctl:
        name: user.max_user_namespaces
        value: "{{ user_namespaces_max }}"
        sysctl_set: true
        state: present
        reload: true

    - name: Allow unprivileged port binding
      become: true
      ansible.posix.sysctl:
        name: net.ipv4.ip_unprivileged_port_start
        value: "0"
        sysctl_set: true
        state: present
        reload: true

    - name: Check subuid entry
      ansible.builtin.command: "grep ^{{ ansible_user_id }}: /etc/subuid"
      register: subuid_check
      changed_when: false
      failed_when: false

    - name: Configure subuid range
      become: true
      ansible.builtin.command: >-
        usermod --add-subuids {{ subuid_start }}-{{ subuid_start + subuid_count - 1 }}
        {{ ansible_user_id }}
      when: subuid_check.rc != 0

    - name: Check subgid entry
      ansible.builtin.command: "grep ^{{ ansible_user_id }}: /etc/subgid"
      register: subgid_check
      changed_when: false
      failed_when: false

    - name: Configure subgid range
      become: true
      ansible.builtin.command: >-
        usermod --add-subgids {{ subuid_start }}-{{ subuid_start + subuid_count - 1 }}
        {{ ansible_user_id }}
      when: subgid_check.rc != 0

    - name: Enable podman socket for current user
      ansible.builtin.systemd:
        name: podman.socket
        scope: user
        enabled: true
        state: started

    - name: Symlink podman socket to /var/run/docker.sock
      become: true
      ansible.builtin.file:
        src: "/run/user/{{ ansible_user_uid }}/podman/podman.sock"
        dest: /var/run/docker.sock
        state: link
        force: true

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
