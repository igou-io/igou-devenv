FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:3397b3751886e669eb873b4dfbebecc9c9e4bc413451d1f2540c62d5b615d6da

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

# ---------------------------------------------------------------------------
# Mise — declarative tool manager. Bootstrap via TOFU SHA256; once installed,
# mise verifies all subsequent tools via aqua-registry's per-tool config
# (cosign/SLSA/GPG/SHA256). See docs/superpowers/specs/2026-05-16-mise-tool-management-design.md
# Manual SHA update on version bump:
#   for a in x64 arm64; do curl -sL "https://github.com/jdx/mise/releases/download/<ver>/mise-<ver>-linux-${a}.tar.gz" | sha256sum; done
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION="v2026.5.16"
ARG MISE_SHA256_AMD64="43c37041c8d5ba3fd1353c3244f2f346866b76f1bafb6c57f059678e1c7a4046"
ARG MISE_SHA256_ARM64="00f94d934a957c67f083669003bc0fd9e6009aec5aa8c6f1649c376f115b3818"
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
COPY aqua-registry/ /etc/mise/aqua-registry/
ENV MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml
# GITHUB_TOKEN is consumed by mise's GitHub-attestations / aqua release-tag
# lookups during install. The 60/hr unauthenticated quota is too small to
# survive a full rebuild of 21 aqua-managed tools; the token bumps it to
# 5000/hr. Declared as ARG (not ENV) so the secret stays out of the final
# image — it's only available to this single RUN layer.
ARG GITHUB_TOKEN=""
RUN set -eux; \
    export GITHUB_TOKEN="${GITHUB_TOKEN}"; \
    mise install --yes; \
    # Symlink installed binaries into /usr/local/bin so they're on PATH
    # for any user without shell activation. mise's per-tool layout is not
    # uniform (some use a bin/ subdir, most put the binary at the install
    # root) — `mise bin-paths` reports each tool's actual bin directory.
    # `-L` is required because http:-backend tools' install dirs are
    # themselves symlinks into /opt/mise/http-tarballs/<hash> — without it
    # find won't traverse past the symlink and the binaries get skipped.
    mise bin-paths | while IFS= read -r d; do \
      find -L "$d" -maxdepth 1 -type f -executable \
        -exec ln -sf {} /usr/local/bin/ \;; \
    done; \
    # Sanity check: kubectl resolves to the mise-installed copy
    kubectl version --client

# oc: migrated to mise (see mise.toml / mise.lock / aqua-registry/oc-postinstall.sh).
# Same GPG trust anchor (Red Hat key 567E347AD0044ADE55BA8A5F199E2F91FD431D51),
# now invoked via mise's postinstall hook after the http-backend download.

# virtctl, kube-burner, kube-burner-ocp: migrated to mise via the http
# backend (see mise.toml / mise.lock). Same blake3-TOFU trust floor as the
# previous inline blocks, but managed through the shared lockfile.

# ---------------------------------------------------------------------------
# Python packages — pinned versions managed by Renovate (requirements.txt)
# ---------------------------------------------------------------------------
COPY builds/podman-socket/requirements.txt /tmp/requirements.txt
RUN pip install --break-system-packages --ignore-installed -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/igou/.config/containers
COPY builds/podman-socket/containers-storage.conf /home/igou/.config/containers/storage.conf
RUN chown -R igou:igou /home/igou/.config

# Claude Code — pinned download, PGP-verified against Anthropic's published key.
# See .devcontainer/Dockerfile for the full trust-anchor rationale.
# renovate: datasource=github-releases depName=anthropics/claude-code
ARG CLAUDE_CODE_VERSION="v2.1.143"
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
