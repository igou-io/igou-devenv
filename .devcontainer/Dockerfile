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
    bubblewrap \
    git \
    wget \
    curl \
    dbus-daemon \
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
    openssl \
    ShellCheck \
    make \
    sshpass \
    gnupg2 \
    genisoimage \
    tree \
    p7zip \
    p7zip-plugins \
    procps-ng \
    openssh-clients \
    iputils \
    libatomic \
    libvirt-client \
    libvirt-daemon \
    libvirt-daemon-config-network \
    libvirt-daemon-driver-qemu \
    libvirt-daemon-driver-storage-core \
    nfs-utils \
    bind-utils \
    edk2-ovmf \
    file \
    htop \
    iperf3 \
    minicom \
    rsync \
    ripgrep \
    screen \
    tmux \
    tftp \
    unzip \
    util-linux \
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
    python3-libvirt \
    python3-netaddr \
    qemu-img \
    qemu-kvm \
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

# Libvirt packages create libvirt + kvm groups at install time. Add igou
# so it can talk to /var/run/libvirt/virtqemud-sock and open /dev/kvm
# without sudo. (Privileged mode + /dev bind-mount makes /dev/kvm
# world-accessible in practice; this is belt-and-suspenders for the
# socket-permission case and for any future tightening of host permissions.)
RUN usermod -aG libvirt,kvm igou

# CS10 ships qemu-kvm at /usr/libexec/qemu-kvm. The molecule_provisioners
# qemu role launches `qemu-system-x86_64` directly; expose it on PATH.
RUN ln -sf /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64

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
# Mise — declarative tool manager. The bootstrap binary is verified against
# mise's GPG-signed release checksums; once installed, mise verifies all
# subsequent tools via aqua-registry's per-tool config (cosign/SLSA/GPG/SHA256).
# See docs/superpowers/specs/2026-05-16-mise-tool-management-design.md
#
# Trust anchor is the pinned key fingerprint below (rsa4096, expires 2028-01-02):
# the key is fetched from mise's HTTPS endpoint at build time but rejected unless
# its fingerprint matches AND the checksums carry a VALIDSIG from it. Renovate
# bumps MISE_VERSION only — there is no per-version SHA to maintain.
# Key UID (cross-checked at keys.openpgp.org and https://mise.jdx.dev/gpg-key.pub):
# "mise releases <release@mise.jdx.dev>"
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION="v2026.7.3"
ARG MISE_GPG_FPR="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"
ARG MISE_GPG_URL="https://mise.jdx.dev/gpg-key.pub"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64" ;; \
      aarch64) ARCH="arm64" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TARBALL="mise-${MISE_VERSION}-linux-${ARCH}.tar.gz"; \
    BASE="https://github.com/jdx/mise/releases/download/${MISE_VERSION}"; \
    WORK=$(mktemp -d); \
    export GNUPGHOME="$WORK/gnupg"; \
    mkdir -p -m 0700 "$GNUPGHOME"; \
    cd "$WORK"; \
    curl -fsSL -o key.asc "${MISE_GPG_URL}"; \
    gpg --batch --import key.asc; \
    # Reject any key whose fingerprint doesn't match the pinned anchor.
    gpg --list-keys --with-colons --with-fingerprint \
      | awk -F: '$1=="fpr"{print $10}' \
      | grep -qFx "${MISE_GPG_FPR}"; \
    curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"; \
    curl -fsSL -o SHASUMS256.asc "${BASE}/SHASUMS256.asc"; \
    # Require a good clearsigned-checksums signature from our pinned key.
    gpg --batch --status-fd 1 --verify SHASUMS256.asc 2>/dev/null \
      | grep -qF "VALIDSIG ${MISE_GPG_FPR}"; \
    # Verify the tarball against its checksum from the signed list.
    gpg --batch --decrypt SHASUMS256.asc 2>/dev/null \
      | awk -v f="./${TARBALL}" '$2==f{print $1"  "f}' \
      | sha256sum -c -; \
    tar -xz --strip-components=2 -C /usr/local/bin -f "$TARBALL" mise/bin/mise; \
    chmod +x /usr/local/bin/mise; \
    cd / && rm -rf "$WORK"; \
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
# 5000/hr.
#
# Provided via a BuildKit secret mount (--mount=type=secret), so the value is
# NEVER written to an image layer or recorded in build history. CI builds pass
# it with `docker buildx build --secret id=github_token,env=GITHUB_TOKEN` and do
# NOT set the build ARG, so the published image is token-free. The ARG below is
# only a fallback for local `make`/Cursor builds, which can't pass a build secret
# through devcontainer.json — a token baked into a local, never-published image
# is acceptable. (Build args leak into image history; secrets do not.)
ARG GITHUB_TOKEN=""
RUN --mount=type=secret,id=github_token set -eux; \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || printf '%s' "${GITHUB_TOKEN}")"; \
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

# ---------------------------------------------------------------------------
# ghapp — runtime-minted, repo-scoped GitHub App tokens (credential helper +
# gh-app/git-app wrappers). Not published to PyPI (the name belongs to
# upstream), so it installs from a pinned git tag. Renovate bumps GHAPP_VERSION
# via the `# renovate:` custom manager (github-tags on the plugin repo). Config
# lives per-user in ~/.config/ghapp/config.yaml (dotfiles/ghapp/config.yaml,
# seeded by post-create.sh); the App private key is read from 1Password at mint
# time, never baked here. See README "GitHub Authentication (ghapp)".
# renovate: datasource=github-tags depName=david-igou/hermes_github_app_plugin
ARG GHAPP_VERSION="v0.2.0"
RUN pip install --break-system-packages \
      "hermes-github-app-plugin @ git+https://github.com/david-igou/hermes_github_app_plugin@${GHAPP_VERSION}"

# Wire the ghapp git credential helper for github.com at the SYSTEM scope: the
# per-user ~/.gitconfig is bind-mounted read-only from the host, so per-user git
# config isn't writable in-container. With this, plain HTTPS `git clone/fetch/push`
# on github.com mints a repo-scoped token via ghapp (useHttpPath gives the helper
# the OWNER/REPO). URLs that embed x-access-token creds bypass the helper, so this
# never fights an explicitly-tokenized remote.
RUN git config --system credential."https://github.com".helper ghapp && \
    git config --system credential."https://github.com".useHttpPath true

# Configure podman for rootless operation inside a container
RUN mkdir -p /home/igou/.config/containers
COPY .devcontainer/containers-storage.conf /home/igou/.config/containers/storage.conf
RUN chown -R igou:igou /home/igou/.config

# Baked CLAUDE.md at the managed enterprise path Claude Code reads automatically.
# This describes the devcontainer to in-container Claude sessions without writing
# to ~/.claude/CLAUDE.md (which is bind-mounted from the host).
RUN mkdir -p /etc/claude-code
COPY .devcontainer/CLAUDE.md /etc/claude-code/CLAUDE.md

# Claude Code — pinned download, verified via Anthropic-signed SHASUMS256.txt.sig.
# Trust anchor is the pinned key fingerprint below: the key is fetched from
# Anthropic's HTTPS endpoint at build time but rejected if its fingerprint
# doesn't match. An attacker would need to both control downloads.claude.ai
# AND produce a colliding SHA-1 fingerprint (computationally infeasible).
# Key UID (out-of-band-verified): "Anthropic Claude Code Release Signing <security@anthropic.com>"
# renovate: datasource=github-releases depName=anthropics/claude-code
ARG CLAUDE_CODE_VERSION="v2.1.210"
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

# Refuse to install unsigned upstream releases (Cursor, opencode, codex)
# younger than this many days. Defense-in-depth against compromised releases
# that haven't been publicly noticed yet — mirrors the coding-agent
# `minimumReleaseAge: 3 days` packageRule in renovate.json at the build layer,
# so it applies even if Renovate is bypassed by a direct edit. 3 days (not the
# global 10): coding-agent CLIs ship harness fixes weekly and staleness has
# real cost on the Hermes terminal backend; everything else keeps the 10-day
# gate from renovate-base.json. Override at build time with:
#   --build-arg MINIMUM_RELEASE_AGE_DAYS=0
ARG MINIMUM_RELEASE_AGE_DAYS=3

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
# be re-captured on version bumps. On Renovate bumps cli-sha-recapture.yaml
# (bin/release-prepare-clis) recaptures these ARGs automatically; for a manual
# bump:
#   curl -sL https://github.com/anomalyco/opencode/releases/download/vX.Y.Z/opencode-linux-x64.tar.gz | sha256sum
#   (repeat for arm64)
# MINIMUM_RELEASE_AGE_DAYS is inherited from the ARG declared above the Cursor block.
# renovate: datasource=github-releases depName=anomalyco/opencode
ARG OPENCODE_VERSION="v1.18.2"
ARG OPENCODE_SHA256_X64="97c95e004bb73d2039f957ea33be0635ea4e22b8dceaedf8f0983765950cf1b6"
ARG OPENCODE_SHA256_ARM64="93352b30d37d8da2e5c226085f1afbf37cf57cfcecedc813520ff2d0f8581540"
# GITHUB_TOKEN authenticates the release-age API call below. Without it the
# 60/hr unauthenticated quota gets exhausted on busy CI runners and the build
# fails with HTTP 403. Provided via a BuildKit secret mount (see the mise block
# above); the ARG is only the local-build fallback and is left empty in CI so the
# published image carries no token.
ARG GITHUB_TOKEN=""
USER igou
RUN --mount=type=secret,id=github_token set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${OPENCODE_SHA256_X64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${OPENCODE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    # Release-age gate: fetch the release's published_at from the GitHub API.
    # Authenticated when GITHUB_TOKEN is set (5000/hr), else unauthenticated (60/hr).
    META_URL="https://api.github.com/repos/anomalyco/opencode/releases/tags/${OPENCODE_VERSION}"; \
    GH_TOKEN_RESOLVED="$(cat /run/secrets/github_token 2>/dev/null || printf '%s' "${GITHUB_TOKEN}")"; \
    AUTH_HEADER=""; \
    [ -n "$GH_TOKEN_RESOLVED" ] && AUTH_HEADER="Authorization: Bearer $GH_TOKEN_RESOLVED"; \
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

# codex CLI (OpenAI) — pinned + SHA256-verified + release-age gated from the
# openai/codex "package" release assets. The native installer
# (https://chatgpt.com/codex/install.sh) lays the standalone payload under
# ~/.codex/packages/standalone; we instead extract it to ~/.local/share/codex
# (like the Claude block above) so the bind-mounted ~/.codex — which holds
# config/auth/state — is never shadowed by an image-baked payload.
# Per-asset SHA256s are published in the release's codex-package_SHA256SUMS;
# cli-sha-recapture.yaml (bin/release-prepare-clis) re-captures them on
# Renovate bumps; for a manual bump:
#   V=0.137.0; curl -fsSL https://github.com/openai/codex/releases/download/rust-v$V/codex-package_SHA256SUMS | grep linux-musl
# Tags are rust-vX.Y.Z, so extractVersion strips the prefix for Renovate.
# MINIMUM_RELEASE_AGE_DAYS is inherited from the ARG declared above the Cursor block.
# Pinned to a release that already clears the age gate (so `make build` and CI
# build clean); Renovate advances it on the same 3-day lag thereafter.
# renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>.+)$
ARG CODEX_VERSION="0.144.4"
ARG CODEX_SHA256_X64="d0a7bdb2ca821c9bb5f4cc2fb11a4ed96025db63b20d1bddf1e632361a108220"
ARG CODEX_SHA256_ARM64="b1bc561a5bf74f9c5767c698275ae8043cee2ce45341098048b0b0b8b4e2cfc5"
# GITHUB_TOKEN authenticates the release-age API call below (see the opencode
# block); provided via a BuildKit secret mount, empty in CI's published image.
ARG GITHUB_TOKEN=""
USER igou
RUN --mount=type=secret,id=github_token set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  TARGET="x86_64-unknown-linux-musl";  EXPECTED_SHA="${CODEX_SHA256_X64}" ;; \
      aarch64) TARGET="aarch64-unknown-linux-musl"; EXPECTED_SHA="${CODEX_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    TAG="rust-v${CODEX_VERSION}"; \
    # Release-age gate: fetch published_at from the GitHub API. Authenticated
    # when GITHUB_TOKEN is set (5000/hr), else unauthenticated (60/hr).
    META_URL="https://api.github.com/repos/openai/codex/releases/tags/${TAG}"; \
    GH_TOKEN_RESOLVED="$(cat /run/secrets/github_token 2>/dev/null || printf '%s' "${GITHUB_TOKEN}")"; \
    AUTH_HEADER=""; \
    [ -n "$GH_TOKEN_RESOLVED" ] && AUTH_HEADER="Authorization: Bearer $GH_TOKEN_RESOLVED"; \
    PUBLISHED_AT=$(curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$META_URL" | jq -r '.published_at'); \
    if [ -z "$PUBLISHED_AT" ] || [ "$PUBLISHED_AT" = "null" ]; then \
      echo "Failed to fetch published_at for codex ${TAG} from $META_URL" >&2; \
      exit 1; \
    fi; \
    RELEASE_EPOCH=$(date -u -d "$PUBLISHED_AT" +%s); \
    AGE_DAYS=$(( ($(date -u +%s) - RELEASE_EPOCH) / 86400 )); \
    if [ "$AGE_DAYS" -lt "${MINIMUM_RELEASE_AGE_DAYS}" ]; then \
      echo "codex ${CODEX_VERSION} is only ${AGE_DAYS} days old (minimum: ${MINIMUM_RELEASE_AGE_DAYS}). Wait, or override with --build-arg MINIMUM_RELEASE_AGE_DAYS=0." >&2; \
      exit 1; \
    fi; \
    TARBALL="codex-package-${TARGET}.tar.gz"; \
    URL="https://github.com/openai/codex/releases/download/${TAG}/${TARBALL}"; \
    DEST="$HOME/.local/share/codex/${CODEX_VERSION}-${TARGET}"; \
    WORK=$(mktemp -d); \
    cd "$WORK"; \
    curl -fsSL -o "$TARBALL" "$URL"; \
    echo "${EXPECTED_SHA}  ${TARBALL}" | sha256sum -c -; \
    mkdir -p "$DEST" "$HOME/.local/bin"; \
    tar -xzf "$TARBALL" -C "$DEST"; \
    chmod 0755 "$DEST/bin/codex" "$DEST/codex-path/rg"; \
    if [ -f "$DEST/codex-resources/bwrap" ]; then chmod 0755 "$DEST/codex-resources/bwrap"; fi; \
    ln -sfn "$DEST/bin/codex" "$HOME/.local/bin/codex"; \
    cd / && rm -rf "$WORK"; \
    "$HOME/.local/bin/codex" --version
USER root

# tmux session-persistence plugins (resurrect + continuum), baked so there is no
# runtime network fetch / TPM. Pinned to commits — tmux-resurrect publishes no
# releases, so both are tracked by commit SHA (bump by hand). Loaded by
# ~/.tmux.conf; the save dir lives on the ~/.local/share/igou-devenv bind mount.
ARG TMUX_RESURRECT_SHA="cff343cf9e81983d3da0c8562b01616f12e8d548"
ARG TMUX_CONTINUUM_SHA="0698e8f4b17d6454c71bf5212895ec055c578da0"
RUN set -eux; \
    git clone https://github.com/tmux-plugins/tmux-resurrect /opt/tmux-plugins/tmux-resurrect; \
    git -C /opt/tmux-plugins/tmux-resurrect checkout "$TMUX_RESURRECT_SHA"; \
    git clone https://github.com/tmux-plugins/tmux-continuum /opt/tmux-plugins/tmux-continuum; \
    git -C /opt/tmux-plugins/tmux-continuum checkout "$TMUX_CONTINUUM_SHA"; \
    rm -rf /opt/tmux-plugins/*/.git

# code-server customizations — bridge devcontainer.json's editor settings +
# Open VSX extensions into the image's default code-server data dir. code-server
# does not read devcontainer.json, so without this the published image (used by
# `make run`, which has no lifecycle hooks) opens with no syntax highlighting.
# `make up` re-runs the same script at start to populate its bind-mounted data
# dir. Single source of truth: .devcontainer/devcontainer.json. Per-extension
# failures (e.g. an ID absent from Open VSX) warn but do not fail the build.
USER igou
COPY --chown=igou:igou .devcontainer/code-server-sync.sh /tmp/code-server-sync.sh
COPY --chown=igou:igou .devcontainer/devcontainer.json /tmp/devcontainer.json
RUN bash /tmp/code-server-sync.sh /tmp/devcontainer.json "$HOME/.local/share/code-server" \
    && rm -f /tmp/code-server-sync.sh /tmp/devcontainer.json
USER root

WORKDIR /workspace
