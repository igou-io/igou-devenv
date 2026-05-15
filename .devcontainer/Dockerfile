FROM quay.io/centos/centos:stream10@sha256:d65dcf6355dba1665660c7771145c2f63b15dbaf06666508213ad7d48145a931

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
    gpg --batch --verify "${TARBALL}.asc" "$TARBALL"; \
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
    gpg --batch --verify SHA256SUMS.sig SHA256SUMS; \
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
    gpg --batch --verify sha256sum.txt.gpg sha256sum.txt; \
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

# kind — pinned + SHA-verified against per-platform .sha256sum.
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION="v0.31.0"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    BIN="kind-linux-${ARCH}"; \
    BASE="https://kind.sigs.k8s.io/dl/${KIND_VERSION}"; \
    curl -fsSL -o /usr/local/bin/kind "${BASE}/${BIN}"; \
    EXPECTED_SHA=$(curl -fsSL "${BASE}/${BIN}.sha256sum" | cut -d' ' -f1); \
    echo "${EXPECTED_SHA}  /usr/local/bin/kind" | sha256sum -c -; \
    chmod +x /usr/local/bin/kind; \
    kind version

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

# direnv — pinned + TOFU-SHA. No upstream checksums or signatures.
# renovate: datasource=github-releases depName=direnv/direnv
ARG DIRENV_VERSION="v2.37.1"
ARG DIRENV_SHA256_AMD64="1f1b93dd6f38523fde26dfac96151ef9d31a374e3005cd3345fb93555ae0c9b5"
ARG DIRENV_SHA256_ARM64="2a9cef8d73521d6a3ec3f2871c4b747b8c4cc038628c1b57a7efa42b393a2d82"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64"; EXPECTED_SHA="${DIRENV_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${DIRENV_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/direnv/direnv/releases/download/${DIRENV_VERSION}/direnv.linux-${ARCH}"; \
    curl -fsSL -o /usr/local/bin/direnv "$URL"; \
    echo "${EXPECTED_SHA}  /usr/local/bin/direnv" | sha256sum -c -; \
    chmod +x /usr/local/bin/direnv; \
    direnv version

# age — pinned + TOFU-SHA. Upstream publishes .proof (sigsum) files but
# verification requires sigsum-verify tool which isn't installed. Follow-up.
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION="v1.3.1"
ARG AGE_SHA256_AMD64="bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377"
ARG AGE_SHA256_ARM64="c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64"; EXPECTED_SHA="${AGE_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${AGE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="age-${AGE_VERSION}-linux-${ARCH}.tar.gz"; \
    URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${TARBALL}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL" "$URL"; \
    echo "${EXPECTED_SHA}  ${TARBALL}" | sha256sum -c -; \
    tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen -f "$TARBALL"; \
    cd / && rm -rf "$WORK"; \
    age --version

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
