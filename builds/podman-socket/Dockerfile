FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:f5a2cf592fd194be54fff4fc8e24388bd7d6b496f4653de7a4e985f41e8dc188

# Create igou user. UID 1000 is a conventional default; the devcontainer runtime's
# updateRemoteUserUID remaps it to match the host user at startup.
# Reassign vscode (UID 1000 in base image) to a different UID first, then create igou.
# vscode is kept because Cursor/VS Code reference it from base image metadata.
RUN usermod -u 65534 -o vscode && \
    groupmod -g 65534 -o vscode && \
    groupadd -g 1000 igou && \
    useradd -m -s /bin/bash -u 1000 -g 1000 -G sudo igou && \
    echo "igou ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/igou

# Additional packages from apt — includes podman/buildah/skopeo for
# native OCI image workflows alongside the Docker CLI compatibility
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    python3-pip \
    python3-venv \
    podman \
    buildah \
    skopeo \
    fuse-overlayfs \
    slirp4netns \
    jq \
    direnv \
    shellcheck \
    make \
    sshpass \
    age \
    gpg \
    tree \
    p7zip-full \
    openssh-client \
    iputils-ping \
    nfs-common \
    adb \
    dnsutils \
    file \
    htop \
    iperf3 \
    iozone3 \
    minicom \
    rsync \
    screen \
    tmux \
    tftp-hpa \
    unzip \
    vim \
    xorriso \
    arp-scan \
    fping \
    ipmitool \
    iproute2 \
    lvm2 \
    mdadm \
    mtr-tiny \
    nmap \
    netcat-openbsd \
    parted \
    python3-netaddr \
    smartmontools \
    snmp \
    socat \
    strace \
    sysstat \
    tcpdump \
    traceroute \
    whois \
    wireguard-tools \
    yamllint \
    && apt-get purge -y --auto-remove gcc g++ cpp gcc-13 g++-13 cpp-13 \
       gcc-13-x86-64-linux-gnu g++-13-x86-64-linux-gnu cpp-13-x86-64-linux-gnu \
       libstdc++-13-dev 2>/dev/null || true \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/i18n/locales /usr/share/locale

# ---------------------------------------------------------------------------
# 1Password CLI (installed via apt repo)
# ---------------------------------------------------------------------------
RUN curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
    > /etc/apt/sources.list.d/1password.list && \
    apt-get update && apt-get install -y 1password-cli && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Docker CLI (via Docker's official apt repo — talks to host via socket mount)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

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
ARG ARGOCD_VERSION="v3.3.8"
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

RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    ARCH_NODE=$([ "$ARCH" = "amd64" ] && echo "x64" || echo "$ARCH"); \
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
    # Architecture aliases for tools that use x86_64/aarch64 naming
    ARCH_X86=$([ "$ARCH" = "amd64" ] && echo "x86_64" || echo "$ARCH"); \
    ARCH_GNU=$([ "$ARCH" = "amd64" ] && echo "x86_64" || echo "aarch64"); \
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
    rm /tmp/rclone.zip

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
