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

# ---------------------------------------------------------------------------
# Mise — declarative tool manager. Bootstrap via TOFU SHA256; once installed,
# mise verifies all subsequent tools via aqua-registry's per-tool config
# (cosign/SLSA/GPG/SHA256). See docs/superpowers/specs/2026-05-16-mise-tool-management-design.md
# Manual SHA update on version bump:
#   for a in x64 arm64; do curl -sL "https://github.com/jdx/mise/releases/download/<ver>/mise-<ver>-linux-${a}.tar.gz" | sha256sum; done
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION="v2026.5.9"
ARG MISE_SHA256_AMD64="66783e315538db21dcc117384dd31662c29ab8b45f0e6d24e8bc174cd419f212"
ARG MISE_SHA256_ARM64="7c855f8c7c8f0d8bb5934aaf924c12a122a016184bb9b23f50e5c1e6997b37c9"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${MISE_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${MISE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${ARCH}.tar.gz"; \
    WORK=$(mktemp -d); \
    curl -fsSL -o "${WORK}/mise.tar.gz" "$URL"; \
    echo "${EXPECTED_SHA}  ${WORK}/mise.tar.gz" | sha256sum -c -; \
    tar -xz --strip-components=2 -C /usr/local/bin -f "${WORK}/mise.tar.gz" mise/bin/mise; \
    chmod +x /usr/local/bin/mise; \
    rm -rf "$WORK"; \
    mise --version

# ---------------------------------------------------------------------------
# Tool installation via mise. mise.toml is the source of truth; mise.lock
# pins per-platform asset URLs + SHA256s. locked=true (in mise.toml settings)
# fails the build if anything drifts.
# ---------------------------------------------------------------------------
COPY mise.toml mise.lock /etc/mise/
ENV MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml
RUN set -eux; \
    mise install --yes; \
    # Symlink installed binaries into /usr/local/bin so they're on PATH
    # for any user without shell activation. mise's per-tool layout is not
    # uniform (some use a bin/ subdir, most put the binary at the install
    # root) — `mise bin-paths` reports each tool's actual bin directory.
    mise bin-paths | while IFS= read -r d; do \
      find "$d" -maxdepth 1 -type f -executable \
        -exec ln -sf {} /usr/local/bin/ \;; \
    done; \
    # Sanity check: kubectl resolves to the mise-installed copy
    kubectl version --client

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

# slsa-verifier — TOFU SHA bootstrap (same chicken-and-egg as cosign).
# Used for argocd: cosign verify-blob-attestation has a 128MB blob size
# limit that argocd's 217MB binary exceeds; slsa-verifier is purpose-built
# for SLSA provenance and is also what argocd's docs recommend.
# Manual SHA update on version bump:
#   for arch in amd64 arm64; do curl -sL "https://github.com/slsa-framework/slsa-verifier/releases/download/<ver>/slsa-verifier-linux-${arch}" | sha256sum; done
# renovate: datasource=github-releases depName=slsa-framework/slsa-verifier
ARG SLSA_VERIFIER_VERSION="v2.7.1"
ARG SLSA_VERIFIER_SHA256_AMD64="946dbec729094195e88ef78e1734324a27869f03e2c6bd2f61cbc06bd5350339"
ARG SLSA_VERIFIER_SHA256_ARM64="5d3b2349ede7bfec19e7a21569f18b9f7410145ad12e9584b175370669e14061"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="amd64"; EXPECTED_SHA="${SLSA_VERIFIER_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${SLSA_VERIFIER_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/slsa-framework/slsa-verifier/releases/download/${SLSA_VERIFIER_VERSION}/slsa-verifier-linux-${ARCH}"; \
    curl -fsSL -o /usr/local/bin/slsa-verifier "$URL"; \
    echo "${EXPECTED_SHA}  /usr/local/bin/slsa-verifier" | sha256sum -c -; \
    chmod +x /usr/local/bin/slsa-verifier; \
    slsa-verifier version

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

# argocd — pinned + SLSA L3 attestation-verified via slsa-verifier.
# slsa-verifier is argocd's documented verification tool. Cosign's
# verify-blob-attestation can't be used here — it has a 128MB blob size
# limit that the 217MB argocd binary exceeds.
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION="v3.3.9"
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
    curl -fsSL -o "$BIN"                  "${BASE}/${BIN}"; \
    curl -fsSL -o cli_checksums.txt       "${BASE}/cli_checksums.txt"; \
    curl -fsSL -o argocd-cli.intoto.jsonl "${BASE}/argocd-cli.intoto.jsonl"; \
    slsa-verifier verify-artifact "$BIN" \
      --provenance-path argocd-cli.intoto.jsonl \
      --source-uri github.com/argoproj/argo-cd \
      --source-tag "${ARGOCD_VERSION}"; \
    grep " ${BIN}\$" cli_checksums.txt | sha256sum -c -; \
    install -m 0755 "$BIN" /usr/local/bin/argocd; \
    cd / && rm -rf "$WORK"; \
    argocd version --client --short

# oc (OpenShift CLI) — pinned to specific z-release + GPG-verified against
# Red Hat's release key 2. Removes the previous "latest" rolling pin.
# Trust anchor: 567E347AD0044ADE55BA8A5F199E2F91FD431D51
# renovate: datasource=custom.openshift-mirror depName=oc
ARG OC_VERSION="4.21.16"
ARG OC_PGP_FPR="567E347AD0044ADE55BA8A5F199E2F91FD431D51"
ARG OC_PGP_URL="https://www.redhat.com/security/data/fd431d51.txt"
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
    curl -fsSL -o sha256sum.txt.gpg "${BASE}/sha256sum.txt.gpg"; \
    # sha256sum.txt.gpg is a binary inline-signed OpenPGP message (NOT a detached
    # signature). --decrypt extracts the plaintext AND verifies the signature in
    # one step; exit 0 means the signature was good and signed by our anchored key.
    gpg --batch --output sha256sum.txt --decrypt sha256sum.txt.gpg; \
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

# ---------------------------------------------------------------------------
# Python packages — pinned versions managed by Renovate (requirements.txt)
# ---------------------------------------------------------------------------
COPY .devcontainer/requirements.txt /tmp/requirements.txt
RUN pip install --break-system-packages --ignore-installed -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/igou/.config/containers
COPY .devcontainer/containers-storage.conf /home/igou/.config/containers/storage.conf
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
