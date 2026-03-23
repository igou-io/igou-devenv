FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:8b4bcf1724083458f8be40f620459d8f36f37a6e44ed1f75c75aa49c51850863

# Tools installed via Features (see devcontainer.json):
#   kubectl, helm, terraform, python, gh, docker-outside-of-docker

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
    tshark \
    whois \
    wireguard-tools \
    yamllint \
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
# CLI tools — pinned versions managed by Renovate
# ---------------------------------------------------------------------------

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
ARG VIRTCTL_VERSION="v1.7.2"
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION="v0.6.7"
# renovate: datasource=github-releases depName=nektos/act
ARG ACT_VERSION="v0.2.84"
# renovate: datasource=github-releases depName=crc-org/crc
ARG CRC_VERSION="v2.59.0"
# renovate: datasource=github-releases depName=cloud-bulldozer/kube-burner
ARG KUBE_BURNER_VERSION="v2.4.2"
# renovate: datasource=github-releases depName=kube-burner/kube-burner-ocp
ARG KUBE_BURNER_OCP_VERSION="v1.11.4"
# renovate: datasource=github-releases depName=tektoncd/cli
ARG TKN_VERSION="v0.44.0"
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION="v1.73.2"

RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
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
    # OpenShift CLI (oc)
    curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz \
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
    # crc (CodeReady Containers / OpenShift Local)
    CRC_VERSION_BARE="${CRC_VERSION#v}"; \
    curl -sSL "https://mirror.openshift.com/pub/openshift-v4/clients/crc/${CRC_VERSION_BARE}/crc-linux-${ARCH}.tar.xz" \
      | tar -xJ -C /tmp && \
    mv /tmp/crc-linux-*/crc /usr/local/bin/ && \
    rm -rf /tmp/crc-linux-*; \
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

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/igou/.config/containers && \
    echo '[storage]' > /home/igou/.config/containers/storage.conf && \
    echo 'driver = "overlay"' >> /home/igou/.config/containers/storage.conf && \
    echo '[storage.options.overlay]' >> /home/igou/.config/containers/storage.conf && \
    echo 'mount_program = "/usr/bin/fuse-overlayfs"' >> /home/igou/.config/containers/storage.conf && \
    chown -R igou:igou /home/igou/.config

# Claude Code — native binary install (replaces deprecated npm package)
USER igou
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

WORKDIR /workspace
