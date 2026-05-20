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
ARG OPENCODE_VERSION="v1.14.46"
ARG OPENCODE_SHA256_X64="19d80c40396930e96afe3f63000bc28d9094760daa16c7b1d7e76dc999cfebcb"
ARG OPENCODE_SHA256_ARM64="eb35ea4a7c777882bcf9d911ee9c8f25e6a4227bbdeda910aa2471deacf3291a"
# GITHUB_TOKEN authenticates the release-age API call below. Without it the
# 60/hr unauthenticated quota gets exhausted on busy CI runners and the build
# fails with HTTP 403. Declared as ARG so the secret stays out of the image.
ARG GITHUB_TOKEN=""
USER igou
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${OPENCODE_SHA256_X64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${OPENCODE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    # Release-age gate: fetch the release's published_at from the GitHub API.
    # Authenticated when GITHUB_TOKEN is set (5000/hr), else unauthenticated (60/hr).
    META_URL="https://api.github.com/repos/anomalyco/opencode/releases/tags/${OPENCODE_VERSION}"; \
    AUTH_HEADER=""; \
    [ -n "${GITHUB_TOKEN}" ] && AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"; \
    PUBLISHED_AT=$(curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$META_URL" | jq -r '.published_at'); \
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
