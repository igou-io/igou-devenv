FROM quay.io/centos/centos:stream10

# Create igou user. UID 1000 is a conventional default; the devcontainer runtime's
# updateRemoteUserUID remaps it to match the host user at startup.
# CentOS uses 'wheel' group for sudo access.
RUN dnf install -y sudo && \
    groupadd -g 1000 igou && \
    useradd -m -s /bin/bash -u 1000 -g 1000 -G wheel igou && \
    echo "igou ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/igou && \
    chmod 440 /etc/sudoers.d/igou && \
    chmod 640 /etc/shadow && \
    dnf clean all

# Enable EPEL for additional packages
RUN dnf install -y epel-release && \
    dnf clean all

# Additional packages from dnf — includes podman/buildah/skopeo for
# native OCI image workflows alongside the Docker CLI compatibility
#
# Packages dropped vs Ubuntu (not available in CentOS Stream 10 + EPEL):
#   adb (android-tools), iozone3, arp-scan
# yamllint installed via pip (ansible-lint dependency) — EPEL build is broken on CS10
RUN dnf install -y \
    git \
    wget \
    curl \
    tar \
    xz \
    python3 \
    python3-pip \
    podman \
    buildah \
    skopeo \
    fuse-overlayfs \
    slirp4netns \
    jq \
    ShellCheck \
    make \
    sshpass \
    gnupg2 \
    tree \
    p7zip \
    p7zip-plugins \
    openssh-clients \
    iputils \
    nfs-utils \
    bind-utils \
    file \
    htop \
    iperf3 \
    minicom \
    rsync \
    screen \
    tmux \
    tftp \
    unzip \
    vim-enhanced \
    xorriso \
    fping \
    ipmitool \
    iproute \
    lvm2 \
    mdadm \
    mtr \
    nmap \
    nmap-ncat \
    parted \
    python3-netaddr \
    smartmontools \
    net-snmp-utils \
    socat \
    strace \
    sysstat \
    tcpdump \
    traceroute \
    whois \
    wireguard-tools \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/i18n/locales /usr/share/locale \
    && chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap

# ---------------------------------------------------------------------------
# 1Password CLI (installed via rpm repo)
# ---------------------------------------------------------------------------
RUN rpm --import https://downloads.1password.com/linux/keys/1password.asc && \
    printf '%s\n' \
        '[1password]' \
        'name=1Password Stable' \
        'baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch' \
        'enabled=1' \
        'gpgcheck=1' \
        'gpgkey=https://downloads.1password.com/linux/keys/1password.asc' \
    > /etc/yum.repos.d/1password.repo && \
    dnf install -y 1password-cli && \
    dnf clean all

# ---------------------------------------------------------------------------
# Docker CLI (via Docker's official rpm repo — talks to host via socket mount)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo \
    -o /etc/yum.repos.d/docker-ce.repo && \
    dnf install -y docker-ce-cli && \
    dnf clean all

# ---------------------------------------------------------------------------
# PAM fix: CentOS Stream 10 ships system-auth as a dangling symlink to
# /etc/authselect/system-auth (authselect is pulled in as a dependency but
# no profile is configured in a minimal container). Replace it so sudo works.
# ---------------------------------------------------------------------------
RUN rm -f /etc/pam.d/system-auth && \
    printf '%s\n' \
        '#%PAM-1.0' \
        'auth      sufficient  pam_rootok.so' \
        'auth      sufficient  pam_unix.so' \
        'account   sufficient  pam_unix.so' \
        'password  sufficient  pam_unix.so' \
        'session   sufficient  pam_unix.so' \
    > /etc/pam.d/system-auth

# ---------------------------------------------------------------------------
# CLI tools — pinned versions managed by Renovate
# ---------------------------------------------------------------------------

# renovate: datasource=node-version depName=node
ARG NODE_VERSION="v24.15.0"
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION="v1.36.0"
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION="v4.1.4"
# renovate: datasource=github-releases depName=hashicorp/terraform
ARG TERRAFORM_VERSION="v1.15.0"
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION="v2.92.0"
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION="v3.3.9"
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/(?<version>.*)$
ARG KUSTOMIZE_VERSION="v5.8.1"
# renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
ARG KUBESEAL_VERSION="v0.36.6"
# renovate: datasource=github-releases depName=fluxcd/flux2
ARG FLUX_VERSION="v2.8.6"
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION="v3.12.2"
# renovate: datasource=github-releases depName=kubevirt/kubevirt
ARG VIRTCTL_VERSION="v1.8.2"
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION="v0.7.0"
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION="v0.31.0"
# renovate: datasource=github-releases depName=nektos/act
ARG ACT_VERSION="v0.2.87"
# renovate: datasource=github-releases depName=cloud-bulldozer/kube-burner
ARG KUBE_BURNER_VERSION="v2.6.1"
# renovate: datasource=github-releases depName=kube-burner/kube-burner-ocp
ARG KUBE_BURNER_OCP_VERSION="v1.11.11"
# renovate: datasource=github-releases depName=tektoncd/cli
ARG TKN_VERSION="v0.44.1"
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION="v1.73.5"
# renovate: datasource=github-releases depName=direnv/direnv
ARG DIRENV_VERSION="v2.37.1"
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION="v1.3.1"

RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    ARCH=$([ "$ARCH_RAW" = "x86_64" ] && echo "amd64" || echo "arm64"); \
    ARCH_NODE=$([ "$ARCH_RAW" = "x86_64" ] && echo "x64" || echo "arm64"); \
    # Node.js (strip headers — not needed at runtime, saves ~65 MB)
    curl -sSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${ARCH_NODE}.tar.xz" \
      | tar -xJ --strip-components=1 -C /usr/local && \
    rm -rf /usr/local/include/node; \
    # kubectl
    curl -sSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl; \
    # helm
    curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin "linux-${ARCH}/helm"; \
    # terraform
    TERRAFORM_VERSION_BARE="${TERRAFORM_VERSION#v}"; \
    curl -sSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION_BARE}/terraform_${TERRAFORM_VERSION_BARE}_linux_${ARCH}.zip" && \
    unzip -o /tmp/terraform.zip -d /usr/local/bin && \
    rm /tmp/terraform.zip; \
    # gh CLI
    GH_VERSION_BARE="${GH_VERSION#v}"; \
    curl -sSL "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION_BARE}_linux_${ARCH}.tar.gz" \
      | tar -xz --strip-components=2 -C /usr/local/bin "gh_${GH_VERSION_BARE}_linux_${ARCH}/bin/gh"; \
    # ArgoCD
    curl -sSL -o /usr/local/bin/argocd \
      "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}" && \
    chmod +x /usr/local/bin/argocd; \
    # kustomize
    curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin kustomize; \
    # kubeseal
    KUBESEAL_VERSION_BARE="${KUBESEAL_VERSION#v}"; \
    curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION_BARE}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin kubeseal; \
    # flux
    curl -sSL "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/flux_${FLUX_VERSION#v}_linux_${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin flux; \
    # sops
    curl -sSL -o /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}" && \
    chmod +x /usr/local/bin/sops; \
    # OpenShift CLI (oc) https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/
    curl -sSL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/openshift-client-linux.tar.gz \
      | tar -xz -C /usr/local/bin oc; \
    # virtctl
    curl -sSL -o /usr/local/bin/virtctl \
      "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-${ARCH}" && \
    chmod +x /usr/local/bin/virtctl; \
    # kubeconform
    curl -sSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin kubeconform; \
    # kind
    curl -sSL -o /usr/local/bin/kind \
      "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" && \
    chmod +x /usr/local/bin/kind; \
    # Architecture aliases for tools that use x86_64/arm64 naming
    ARCH_X86=$([ "$ARCH_RAW" = "x86_64" ] && echo "x86_64" || echo "arm64"); \
    ARCH_GNU=$ARCH_RAW; \
    # act
    curl -sSL "https://github.com/nektos/act/releases/download/${ACT_VERSION}/act_Linux_${ARCH_X86}.tar.gz" \
      | tar -xz -C /usr/local/bin act; \
    # kube-burner
    KB_VERSION_BARE="${KUBE_BURNER_VERSION#v}"; \
    curl -sSL "https://github.com/cloud-bulldozer/kube-burner/releases/download/${KUBE_BURNER_VERSION}/kube-burner-V${KB_VERSION_BARE}-linux-${ARCH_X86}.tar.gz" \
      | tar -xz -C /usr/local/bin kube-burner; \
    # kube-burner-ocp
    KBO_VERSION_BARE="${KUBE_BURNER_OCP_VERSION#v}"; \
    curl -sSL "https://github.com/kube-burner/kube-burner-ocp/releases/download/${KUBE_BURNER_OCP_VERSION}/kube-burner-ocp-V${KBO_VERSION_BARE}-linux-${ARCH_X86}.tar.gz" \
      | tar -xz -C /usr/local/bin kube-burner-ocp; \
    # tkn (Tekton CLI)
    TKN_VERSION_BARE="${TKN_VERSION#v}"; \
    curl -sSL "https://github.com/tektoncd/cli/releases/download/${TKN_VERSION}/tkn_${TKN_VERSION_BARE}_Linux_${ARCH_GNU}.tar.gz" \
      | tar -xz -C /usr/local/bin tkn; \
    # mc (MinIO client — rolling release, no version pin)
    curl -sSL -o /usr/local/bin/mc "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" && \
    chmod +x /usr/local/bin/mc; \
    # rclone
    curl -sSL -o /tmp/rclone.zip \
      "https://github.com/rclone/rclone/releases/download/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip" && \
    unzip -j /tmp/rclone.zip "rclone-${RCLONE_VERSION}-linux-${ARCH}/rclone" -d /usr/local/bin && \
    chmod +x /usr/local/bin/rclone && \
    rm /tmp/rclone.zip; \
    # direnv (not available in CentOS repos)
    curl -sSL -o /usr/local/bin/direnv \
      "https://github.com/direnv/direnv/releases/download/${DIRENV_VERSION}/direnv.linux-${ARCH}" && \
    chmod +x /usr/local/bin/direnv; \
    # age (not available in CentOS repos)
    curl -sSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen

# ---------------------------------------------------------------------------
# Python packages — pinned versions managed by Renovate (requirements.txt)
# ---------------------------------------------------------------------------
COPY requirements.txt /tmp/requirements.txt
RUN pip install --break-system-packages --ignore-installed -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/igou/.config/containers
COPY containers-storage.conf /home/igou/.config/containers/storage.conf
RUN chown -R igou:igou /home/igou/.config

# Claude Code — pinned download, verified via Anthropic-signed SHASUMS256.txt.sig.
# Trust anchor is the pinned key fingerprint below: the key is fetched from
# Anthropic's HTTPS endpoint at build time but rejected if its fingerprint
# doesn't match. An attacker would need to both control downloads.claude.ai
# AND produce a colliding SHA-1 fingerprint (computationally infeasible).
# Key UID (out-of-band-verified): "Anthropic Claude Code Release Signing <security@anthropic.com>"
# renovate: datasource=github-releases depName=anthropics/claude-code
ARG CLAUDE_CODE_VERSION="v2.1.142"
ARG CLAUDE_CODE_PGP_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
ARG CLAUDE_CODE_PGP_URL="https://downloads.claude.ai/keys/claude-code.asc"
USER igou
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="claude-linux-${ARCH}.tar.gz"; \
    BASE="https://github.com/anthropics/claude-code/releases/download/${CLAUDE_CODE_VERSION}"; \
    WORK=$(mktemp -d); \
    export GNUPGHOME="$WORK/gnupg"; \
    mkdir -p -m 0700 "$GNUPGHOME"; \
    cd "$WORK"; \
    curl -fsSL -o key.asc "${CLAUDE_CODE_PGP_URL}"; \
    gpg --batch --import key.asc; \
    # Reject any key whose fingerprint doesn't match the pinned anchor.
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${CLAUDE_CODE_PGP_FPR}"; \
    curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"; \
    curl -fsSL -o SHASUMS256.txt "${BASE}/SHASUMS256.txt"; \
    curl -fsSL -o SHASUMS256.txt.sig "${BASE}/SHASUMS256.txt.sig"; \
    # Require not just a valid signature, but one from our pinned key.
    # gpg's --status-fd emits "VALIDSIG <fpr>" only on a good signature from <fpr>.
    gpg --batch --status-fd 1 --verify SHASUMS256.txt.sig SHASUMS256.txt 2>/dev/null \
      | grep -qF "VALIDSIG ${CLAUDE_CODE_PGP_FPR}"; \
    grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c -; \
    mkdir -p "$HOME/.local/share/claude" "$HOME/.local/bin"; \
    tar -xzf "$TARBALL" -C "$HOME/.local/share/claude"; \
    ln -sfn "$HOME/.local/share/claude/claude" "$HOME/.local/bin/claude"; \
    cd / && rm -rf "$WORK"; \
    "$HOME/.local/bin/claude" --version
USER root

# Refuse to install unsigned upstream releases (Cursor, opencode) younger than
# this many days. Defense-in-depth against compromised releases that haven't
# been publicly noticed yet — mirrors `minimumReleaseAge: 10` in
# renovate-base.json at the build layer, so it applies even if Renovate is
# bypassed by a direct edit. Override at build time with:
#   --build-arg MINIMUM_RELEASE_AGE_DAYS=0
ARG MINIMUM_RELEASE_AGE_DAYS=10

# Cursor agent CLI — pinned + SHA256-verified + release-age gated. No upstream
# SHASUMS file is published; SHAs must be re-captured on version bumps.
# Manual update process:
#   curl -sL https://cursor.com/install | grep -oP "lab/\K[0-9a-zA-Z.-]+"
#   curl -sL "https://downloads.cursor.com/lab/<VER>/linux/x64/agent-cli-package.tar.gz" | sha256sum
#   (repeat for arm64)
ARG CURSOR_AGENT_VERSION="2026.05.01-eea359f"
ARG CURSOR_AGENT_SHA256_X64="63b17a0ec0f4b73bf3ed540a24d51391bfe01c37d5961dffadcbbf1a8b02499c"
ARG CURSOR_AGENT_SHA256_ARM64="8c06f06834c7472b68df07353462889c7b284b280a2a3a323ea1dfd26972ade9"
USER igou
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${CURSOR_AGENT_SHA256_X64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${CURSOR_AGENT_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    # Release-age gate: Cursor version strings are YYYY.MM.DD-<short-sha>, so we
    # parse the date directly from the pinned version — no upstream API call.
    DATE_PART="${CURSOR_AGENT_VERSION%-*}"; \
    case "$DATE_PART" in \
      [0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;; \
      *) echo "Unexpected Cursor version format (expected YYYY.MM.DD-<sha>): ${CURSOR_AGENT_VERSION}" >&2; exit 1 ;; \
    esac; \
    RELEASE_EPOCH=$(date -u -d "$(echo "$DATE_PART" | tr . -)" +%s); \
    AGE_DAYS=$(( ($(date -u +%s) - RELEASE_EPOCH) / 86400 )); \
    if [ "$AGE_DAYS" -lt "${MINIMUM_RELEASE_AGE_DAYS}" ]; then \
      echo "Cursor agent ${CURSOR_AGENT_VERSION} is only ${AGE_DAYS} days old (minimum: ${MINIMUM_RELEASE_AGE_DAYS}). Wait, or override with --build-arg MINIMUM_RELEASE_AGE_DAYS=0." >&2; \
      exit 1; \
    fi; \
    URL="https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${ARCH}/agent-cli-package.tar.gz"; \
    DEST="$HOME/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o agent.tar.gz "$URL"; \
    echo "${EXPECTED_SHA}  agent.tar.gz" | sha256sum -c -; \
    mkdir -p "$DEST" "$HOME/.local/bin"; \
    tar -xzf agent.tar.gz -C "$DEST" --strip-components=1; \
    ln -sfn "$DEST/cursor-agent" "$HOME/.local/bin/agent"; \
    ln -sfn "$DEST/cursor-agent" "$HOME/.local/bin/cursor-agent"; \
    cd / && rm -rf "$WORK"; \
    "$HOME/.local/bin/agent" --version
USER root

# opencode CLI — pinned + SHA256-verified + release-age gated from
# anomalyco/opencode releases. No upstream SHASUMS file is published; SHAs must
# be re-captured on version bumps. Manual update process:
#   curl -sL https://github.com/anomalyco/opencode/releases/download/vX.Y.Z/opencode-linux-x64.tar.gz | sha256sum
#   (repeat for arm64)
# MINIMUM_RELEASE_AGE_DAYS is inherited from the ARG declared above the Cursor block.
# renovate: datasource=github-releases depName=anomalyco/opencode
ARG OPENCODE_VERSION="v1.14.30"
ARG OPENCODE_SHA256_X64="13b2dd32c5549f7b031e8bb67fb8d6e8d87aa9e07bd6f0017620836f1fb7cdce"
ARG OPENCODE_SHA256_ARM64="ca86ae22b1db986650eac4e3017539e15570569689fb6724cb8f33c0e4cdf668"
USER igou
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${OPENCODE_SHA256_X64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${OPENCODE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    # Release-age gate: fetch the release's published_at from the GitHub API.
    # No auth needed (public repo); rate limits are 60/hr unauthenticated.
    META_URL="https://api.github.com/repos/anomalyco/opencode/releases/tags/${OPENCODE_VERSION}"; \
    PUBLISHED_AT=$(curl -fsSL "$META_URL" | jq -r '.published_at'); \
    if [ -z "$PUBLISHED_AT" ] || [ "$PUBLISHED_AT" = "null" ]; then \
      echo "Failed to fetch published_at for opencode ${OPENCODE_VERSION} from $META_URL" >&2; \
      exit 1; \
    fi; \
    RELEASE_EPOCH=$(date -u -d "$PUBLISHED_AT" +%s); \
    AGE_DAYS=$(( ($(date -u +%s) - RELEASE_EPOCH) / 86400 )); \
    if [ "$AGE_DAYS" -lt "${MINIMUM_RELEASE_AGE_DAYS}" ]; then \
      echo "opencode ${OPENCODE_VERSION} is only ${AGE_DAYS} days old (minimum: ${MINIMUM_RELEASE_AGE_DAYS}). Wait, or override with --build-arg MINIMUM_RELEASE_AGE_DAYS=0." >&2; \
      exit 1; \
    fi; \
    TARBALL="opencode-linux-${ARCH}.tar.gz"; \
    URL="https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/${TARBALL}"; \
    DEST="$HOME/.opencode/bin"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL" "$URL"; \
    echo "${EXPECTED_SHA}  ${TARBALL}" | sha256sum -c -; \
    mkdir -p "$DEST" "$HOME/.local/bin"; \
    tar -xzf "$TARBALL" -C "$DEST"; \
    chmod +x "$DEST/opencode"; \
    ln -sfn "$DEST/opencode" "$HOME/.local/bin/opencode"; \
    cd / && rm -rf "$WORK"; \
    "$HOME/.local/bin/opencode" --version
USER root

WORKDIR /workspace
