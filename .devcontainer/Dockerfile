FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:8b4bcf1724083458f8be40f620459d8f36f37a6e44ed1f75c75aa49c51850863

# Tools installed via Features (see devcontainer.json):
#   kubectl, helm, terraform, tflint, go, python, gh, docker-in-docker, claude-code

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
    && rm -rf /var/lib/apt/lists/*

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
ARG ARGOCD_VERSION="v3.3.0"
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
    chmod +x /usr/local/bin/virtctl

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/vscode/.config/containers && \
    echo '[storage]' > /home/vscode/.config/containers/storage.conf && \
    echo 'driver = "overlay"' >> /home/vscode/.config/containers/storage.conf && \
    echo '[storage.options.overlay]' >> /home/vscode/.config/containers/storage.conf && \
    echo 'mount_program = "/usr/bin/fuse-overlayfs"' >> /home/vscode/.config/containers/storage.conf && \
    chown -R vscode:vscode /home/vscode/.config/containers

# Create workspace directory for cloning repos
RUN mkdir -p /workspace && chown vscode:vscode /workspace
WORKDIR /workspace
