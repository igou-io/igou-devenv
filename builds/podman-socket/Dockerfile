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

# cosign — sigstore CLI. Bootstrap via TOFU SHA256 because we can't verify
# cosign with cosign yet. Once installed, used to verify flux/sops/argocd.
# Manual SHA update on version bump:
#   curl -sL https://github.com/sigstore/cosign/releases/download/<ver>/cosign_checksums.txt | grep -E 'cosign-linux-(amd64|arm64)$'
# renovate: datasource=github-releases depName=sigstore/cosign
ARG COSIGN_VERSION="v3.0.6"
ARG COSIGN_SHA256_AMD64="c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74"
ARG COSIGN_SHA256_ARM64="bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64"; EXPECTED_SHA="${COSIGN_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${COSIGN_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${ARCH}"; \
    curl -fsSL -o /usr/local/bin/cosign "$URL"; \
    echo "${EXPECTED_SHA}  /usr/local/bin/cosign" | sha256sum -c -; \
    chmod +x /usr/local/bin/cosign; \
    cosign version

# Node.js — out of H3 scope (not in audit list). Preserves existing
# unverified install.
# renovate: datasource=node-version depName=node
ARG NODE_VERSION="v24.15.0"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    ARCH_NODE=$([ "$ARCH_RAW" = "x86_64" ] && echo "x64" || echo "arm64"); \
    curl -sSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${ARCH_NODE}.tar.xz" \
      | tar -xJ --strip-components=1 -C /usr/local && \
    rm -rf /usr/local/include/node

# kubectl — pinned + SHA-verified against dl.k8s.io publisher checksum.
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION="v1.36.0"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BASE="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}"; \
    curl -fsSL -o /usr/local/bin/kubectl "${BASE}/kubectl"; \
    EXPECTED_SHA=$(curl -fsSL "${BASE}/kubectl.sha256"); \
    echo "${EXPECTED_SHA}  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

# helm — pinned + GPG-verified against Helm's release signing key.
# Trust anchor: BF888333D96A1C18E2682AAED79D67C9EC016739
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION="v4.1.4"
ARG HELM_PGP_FPR="BF888333D96A1C18E2682AAED79D67C9EC016739"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"; \
    TARBALL_URL="https://get.helm.sh/${TARBALL}"; \
    ASC_URL="https://github.com/helm/helm/releases/download/${HELM_VERSION}/${TARBALL}.asc"; \
    KEYS_URL="https://raw.githubusercontent.com/helm/helm/main/KEYS"; \
    WORK=$(mktemp -d); \
    export GNUPGHOME="$WORK/gnupg"; \
    mkdir -p -m 0700 "$GNUPGHOME"; \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL" "$TARBALL_URL"; \
    curl -fsSL -o "${TARBALL}.asc" "$ASC_URL"; \
    curl -fsSL -o key.asc "$KEYS_URL"; \
    gpg --batch --import key.asc; \
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${HELM_PGP_FPR}"; \
    gpg --batch --status-fd 1 --verify "${TARBALL}.asc" "$TARBALL" 2>/dev/null \
      | grep -qF "VALIDSIG ${HELM_PGP_FPR}"; \
    tar -xz --strip-components=1 -C /usr/local/bin "linux-${ARCH}/helm" -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    helm version --short

# terraform — pinned + GPG-verified against HashiCorp's release key.
# Trust anchor: C874011F0AB405110D02105534365D9472D7468F (HashiCorp key 72D7468F)
# renovate: datasource=github-releases depName=hashicorp/terraform
ARG TERRAFORM_VERSION="v1.15.0"
ARG TERRAFORM_PGP_FPR="C874011F0AB405110D02105534365D9472D7468F"
ARG TERRAFORM_PGP_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TF_VER_BARE="${TERRAFORM_VERSION#v}"; \
    ZIP="terraform_${TF_VER_BARE}_linux_${ARCH}.zip"; \
    BASE="https://releases.hashicorp.com/terraform/${TF_VER_BARE}"; \
    WORK=$(mktemp -d); \
    export GNUPGHOME="$WORK/gnupg"; \
    mkdir -p -m 0700 "$GNUPGHOME"; \
    cd "$WORK"; \
    curl -fsSL -o key.asc "${TERRAFORM_PGP_URL}"; \
    gpg --batch --import key.asc; \
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${TERRAFORM_PGP_FPR}"; \
    curl -fsSL -o SHA256SUMS     "${BASE}/terraform_${TF_VER_BARE}_SHA256SUMS"; \
    curl -fsSL -o SHA256SUMS.sig "${BASE}/terraform_${TF_VER_BARE}_SHA256SUMS.sig"; \
    gpg --batch --status-fd 1 --verify SHA256SUMS.sig SHA256SUMS 2>/dev/null \
      | grep -qF "VALIDSIG ${TERRAFORM_PGP_FPR}"; \
    curl -fsSL -o "$ZIP" "${BASE}/${ZIP}"; \
    grep " ${ZIP}\$" SHA256SUMS | sha256sum -c -; \
    unzip -o "$ZIP" -d /usr/local/bin; \
    cd / && rm -rf "$WORK"; \
    terraform version

# gh — pinned + SHA-verified against upstream checksums.txt.
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION="v2.92.0"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    GH_BARE="${GH_VERSION#v}"; \
    TARBALL="gh_${GH_BARE}_linux_${ARCH}.tar.gz"; \
    BASE="https://github.com/cli/cli/releases/download/${GH_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"        "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt     "${BASE}/gh_${GH_BARE}_checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz --strip-components=2 -C /usr/local/bin "gh_${GH_BARE}_linux_${ARCH}/bin/gh" -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    gh --version

# argocd — pinned + SLSA L3 attestation-verified via cosign.
# Trust anchor: cosign cert-identity-regexp + GitHub OIDC issuer.
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION="v3.3.9"
ARG ARGOCD_CERT_IDENTITY_REGEXP="^https://github.com/argoproj/argo-cd/.*"
ARG ARGOCD_CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BIN="argocd-linux-${ARCH}"; \
    BASE="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$BIN"                "${BASE}/${BIN}"; \
    curl -fsSL -o cli_checksums.txt     "${BASE}/cli_checksums.txt"; \
    curl -fsSL -o argocd-cli.intoto.jsonl "${BASE}/argocd-cli.intoto.jsonl"; \
    cosign verify-blob-attestation \
      --type slsaprovenance \
      --bundle argocd-cli.intoto.jsonl \
      --certificate-identity-regexp "${ARGOCD_CERT_IDENTITY_REGEXP}" \
      --certificate-oidc-issuer "${ARGOCD_CERT_OIDC_ISSUER}" \
      "$BIN"; \
    grep " ${BIN}\$" cli_checksums.txt | sha256sum -c -; \
    install -m 0755 "$BIN" /usr/local/bin/argocd; \
    cd / && rm -rf "$WORK"; \
    argocd version --client --short

# kustomize — pinned + SHA-verified against upstream checksums.txt.
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/(?<version>.*)$
ARG KUSTOMIZE_VERSION="v5.8.1"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"; \
    BASE="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"    "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin kustomize -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    kustomize version

# kubeseal — pinned + SHA-verified against upstream sealed-secrets_*_checksums.txt.
# NOTE: Upstream publishes .sig files but no companion .pem certificates, so
# cosign-keyless verification of the checksums file isn't possible from release
# assets alone. Downgraded to Tier 2 (SHA-only) until upstream clarifies — see
# follow-up issue in PR description.
# renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
ARG KUBESEAL_VERSION="v0.36.6"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    KS_BARE="${KUBESEAL_VERSION#v}"; \
    TARBALL="kubeseal-${KS_BARE}-linux-${ARCH}.tar.gz"; \
    BASE="https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"    "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/sealed-secrets_${KS_BARE}_checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin kubeseal -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    kubeseal --version

# flux — pinned + cosign-keyless-verified against signed checksums.txt.
# Trust anchor: cosign cert-identity-regexp + GitHub OIDC issuer.
# renovate: datasource=github-releases depName=fluxcd/flux2
ARG FLUX_VERSION="v2.8.6"
ARG FLUX_CERT_IDENTITY_REGEXP="^https://github.com/fluxcd/flux2/.*"
ARG FLUX_CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    FLUX_BARE="${FLUX_VERSION#v}"; \
    TARBALL="flux_${FLUX_BARE}_linux_${ARCH}.tar.gz"; \
    BASE="https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"           "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt        "${BASE}/flux_${FLUX_BARE}_checksums.txt"; \
    curl -fsSL -o checksums.txt.sig    "${BASE}/flux_${FLUX_BARE}_checksums.txt.sig"; \
    curl -fsSL -o checksums.txt.pem    "${BASE}/flux_${FLUX_BARE}_checksums.txt.pem"; \
    cosign verify-blob \
      --certificate checksums.txt.pem \
      --signature checksums.txt.sig \
      --certificate-identity-regexp "${FLUX_CERT_IDENTITY_REGEXP}" \
      --certificate-oidc-issuer "${FLUX_CERT_OIDC_ISSUER}" \
      checksums.txt; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin flux -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    flux --version

# sops — pinned + cosign-keyless-verified against checksums.sigstore.json bundle.
# Trust anchor: cosign cert-identity-regexp + GitHub OIDC issuer.
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION="v3.12.2"
ARG SOPS_CERT_IDENTITY_REGEXP="^https://github.com/getsops/.*"
ARG SOPS_CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BIN="sops-${SOPS_VERSION}.linux.${ARCH}"; \
    BASE="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$BIN"                       "${BASE}/${BIN}"; \
    curl -fsSL -o checksums.txt                "${BASE}/sops-${SOPS_VERSION}.checksums.txt"; \
    curl -fsSL -o checksums.sigstore.json      "${BASE}/sops-${SOPS_VERSION}.checksums.sigstore.json"; \
    cosign verify-blob \
      --bundle checksums.sigstore.json \
      --certificate-identity-regexp "${SOPS_CERT_IDENTITY_REGEXP}" \
      --certificate-oidc-issuer "${SOPS_CERT_OIDC_ISSUER}" \
      checksums.txt; \
    grep " ${BIN}\$" checksums.txt | sha256sum -c -; \
    install -m 0755 "$BIN" /usr/local/bin/sops; \
    cd / && rm -rf "$WORK"; \
    sops --version

# oc (OpenShift CLI) — pinned to specific z-release + GPG-verified against
# Red Hat's release key 2. Removes the previous "latest" rolling pin.
# Trust anchor: 567E347AD0044ADE55BA8A5F199E2F91FD431D51
# renovate: datasource=custom.openshift-mirror depName=oc
ARG OC_VERSION="4.21.16"
ARG OC_PGP_FPR="567E347AD0044ADE55BA8A5F199E2F91FD431D51"
ARG OC_PGP_URL="https://access.redhat.com/sites/default/files/pages/attachments/RPM-GPG-KEY-redhat-release"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x86_64" ;; \
      aarch64) ARCH="aarch64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BASE="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_VERSION}"; \
    TARBALL="openshift-client-linux.tar.gz"; \
    WORK=$(mktemp -d); \
    export GNUPGHOME="$WORK/gnupg"; \
    mkdir -p -m 0700 "$GNUPGHOME"; \
    cd "$WORK"; \
    curl -fsSL -o key.asc "${OC_PGP_URL}"; \
    gpg --batch --import key.asc; \
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${OC_PGP_FPR}"; \
    curl -fsSL -o sha256sum.txt     "${BASE}/sha256sum.txt"; \
    curl -fsSL -o sha256sum.txt.gpg "${BASE}/sha256sum.txt.gpg"; \
    gpg --batch --status-fd 1 --verify sha256sum.txt.gpg sha256sum.txt 2>/dev/null \
      | grep -qF "VALIDSIG ${OC_PGP_FPR}"; \
    curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"; \
    grep " ${TARBALL}\$" sha256sum.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin oc -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    oc version --client

# virtctl — pinned + TOFU-SHA. No upstream verification for binary assets.
# Update both per-arch SHAs on version bump.
# renovate: datasource=github-releases depName=kubevirt/kubevirt
ARG VIRTCTL_VERSION="v1.8.2"
ARG VIRTCTL_SHA256_AMD64="745f3c58c6a77be65b828e67b6ad930e9039ab293ed5b2bef6d44c8681af5b75"
ARG VIRTCTL_SHA256_ARM64="345b29874d3c98801ad022ef3074b21e2b21a386b22a2779997ab7c74c7e6f57"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64"; EXPECTED_SHA="${VIRTCTL_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${VIRTCTL_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BIN="virtctl-${VIRTCTL_VERSION}-linux-${ARCH}"; \
    URL="https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/${BIN}"; \
    curl -fsSL -o /usr/local/bin/virtctl "$URL"; \
    echo "${EXPECTED_SHA}  /usr/local/bin/virtctl" | sha256sum -c -; \
    chmod +x /usr/local/bin/virtctl; \
    virtctl version --client

# kubeconform — pinned + SHA-verified against CHECKSUMS.
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION="v0.7.0"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="kubeconform-linux-${ARCH}.tar.gz"; \
    BASE="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"   "${BASE}/${TARBALL}"; \
    curl -fsSL -o CHECKSUMS    "${BASE}/CHECKSUMS"; \
    grep " ${TARBALL}\$" CHECKSUMS | sha256sum -c -; \
    tar -xz -C /usr/local/bin kubeconform -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    kubeconform -v

# act — pinned + SHA-verified against checksums.txt.
# renovate: datasource=github-releases depName=nektos/act
ARG ACT_VERSION="v0.2.87"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH_X86="x86_64" ;; \
      aarch64) ARCH_X86="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="act_Linux_${ARCH_X86}.tar.gz"; \
    BASE="https://github.com/nektos/act/releases/download/${ACT_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"   "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin act -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    act --version

# kube-burner — pinned + SHA-verified against kube-burner-checksums.txt.
# renovate: datasource=github-releases depName=cloud-bulldozer/kube-burner
ARG KUBE_BURNER_VERSION="v2.6.1"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH_X86="x86_64" ;; \
      aarch64) ARCH_X86="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    KB_BARE="${KUBE_BURNER_VERSION#v}"; \
    TARBALL="kube-burner-V${KB_BARE}-linux-${ARCH_X86}.tar.gz"; \
    BASE="https://github.com/cloud-bulldozer/kube-burner/releases/download/${KUBE_BURNER_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"   "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/kube-burner-checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin kube-burner -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    kube-burner version

# kube-burner-ocp — pinned + SHA-verified.
# renovate: datasource=github-releases depName=kube-burner/kube-burner-ocp
ARG KUBE_BURNER_OCP_VERSION="v1.11.11"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH_X86="x86_64" ;; \
      aarch64) ARCH_X86="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    KBO_BARE="${KUBE_BURNER_OCP_VERSION#v}"; \
    TARBALL="kube-burner-ocp-V${KBO_BARE}-linux-${ARCH_X86}.tar.gz"; \
    BASE="https://github.com/kube-burner/kube-burner-ocp/releases/download/${KUBE_BURNER_OCP_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"   "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/kube-burner-ocp-checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin kube-burner-ocp -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    kube-burner-ocp version

# tkn (Tekton CLI) — pinned + SHA-verified.
# renovate: datasource=github-releases depName=tektoncd/cli
ARG TKN_VERSION="v0.44.1"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH_GNU="x86_64" ;; \
      aarch64) ARCH_GNU="aarch64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TKN_BARE="${TKN_VERSION#v}"; \
    TARBALL="tkn_${TKN_BARE}_Linux_${ARCH_GNU}.tar.gz"; \
    BASE="https://github.com/tektoncd/cli/releases/download/${TKN_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL"   "${BASE}/${TARBALL}"; \
    curl -fsSL -o checksums.txt "${BASE}/checksums.txt"; \
    grep " ${TARBALL}\$" checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin tkn -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    tkn version --client

# rclone — pinned + SHA-verified.
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION="v1.73.5"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    ZIP="rclone-${RCLONE_VERSION}-linux-${ARCH}.zip"; \
    BASE="https://github.com/rclone/rclone/releases/download/${RCLONE_VERSION}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$ZIP"        "${BASE}/${ZIP}"; \
    curl -fsSL -o SHA256SUMS    "${BASE}/SHA256SUMS"; \
    grep " ${ZIP}\$" SHA256SUMS | sha256sum -c -; \
    unzip -j "$ZIP" "rclone-${RCLONE_VERSION}-linux-${ARCH}/rclone" -d /usr/local/bin; \
    chmod +x /usr/local/bin/rclone; \
    cd / && rm -rf "$WORK"; \
    rclone version

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

# Claude Code — pinned download, PGP-verified against Anthropic's published key.
# See .devcontainer/Dockerfile for the full trust-anchor rationale.
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
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${CLAUDE_CODE_PGP_FPR}"; \
    curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"; \
    curl -fsSL -o SHASUMS256.txt "${BASE}/SHASUMS256.txt"; \
    curl -fsSL -o SHASUMS256.txt.sig "${BASE}/SHASUMS256.txt.sig"; \
    gpg --batch --status-fd 1 --verify SHASUMS256.txt.sig SHASUMS256.txt 2>/dev/null \
      | grep -qF "VALIDSIG ${CLAUDE_CODE_PGP_FPR}"; \
    grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c -; \
    mkdir -p "$HOME/.local/share/claude" "$HOME/.local/bin"; \
    tar -xzf "$TARBALL" -C "$HOME/.local/share/claude"; \
    ln -sfn "$HOME/.local/share/claude/claude" "$HOME/.local/bin/claude"; \
    cd / && rm -rf "$WORK"; \
    "$HOME/.local/bin/claude" --version
USER root

# Refuse to install unsigned upstream releases younger than this many days.
# See .devcontainer/Dockerfile for full rationale. Override with:
#   --build-arg MINIMUM_RELEASE_AGE_DAYS=0
ARG MINIMUM_RELEASE_AGE_DAYS=10

# Cursor agent CLI — pinned + SHA256-verified + release-age gated. No upstream
# signature available (feature requested upstream since 2023, still unimplemented).
# See .devcontainer/Dockerfile for the manual SHA-update procedure.
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

WORKDIR /workspace
