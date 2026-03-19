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
    nfs-common \
    && rm -rf /var/lib/apt/lists/*

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