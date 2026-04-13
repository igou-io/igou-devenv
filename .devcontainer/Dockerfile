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
ARG NODE_VERSION="v24.14.1"
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION="v1.35.3"
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION="v4.1.3"
# renovate: datasource=github-releases depName=hashicorp/terraform
ARG TERRAFORM_VERSION="v1.14.8"
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION="v2.89.0"
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION="v3.3.4"
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/(?<version>.*)$
ARG KUSTOMIZE_VERSION="v5.8.1"
# renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
ARG KUBESEAL_VERSION="v0.36.1"
# renovate: datasource=github-releases depName=fluxcd/flux2
ARG FLUX_VERSION="v2.8.3"
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION="v3.12.2"
# renovate: datasource=github-releases depName=kubevirt/kubevirt
ARG VIRTCTL_VERSION="v1.8.1"
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION="v0.7.0"
# renovate: datasource=github-releases depName=nektos/act
ARG ACT_VERSION="v0.2.84"
# renovate: datasource=github-releases depName=cloud-bulldozer/kube-burner
ARG KUBE_BURNER_VERSION="v2.5.1"
# renovate: datasource=github-releases depName=kube-burner/kube-burner-ocp
ARG KUBE_BURNER_OCP_VERSION="v1.11.4"
# renovate: datasource=github-releases depName=tektoncd/cli
ARG TKN_VERSION="v0.44.0"
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION="v1.73.2"
# renovate: datasource=github-releases depName=direnv/direnv
ARG DIRENV_VERSION="v2.35.0"
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION="v1.2.1"

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

# Claude Code — native binary install (replaces deprecated npm package)
USER igou
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# Cursor agent CLI
USER igou
RUN curl -fsSL https://cursor.com/install | bash && \
    ~/.local/bin/agent --version
USER root

WORKDIR /workspace
