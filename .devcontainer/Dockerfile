FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Tools installed via Features (see devcontainer.json):
#   kubectl, helm, terraform, tflint, go, python, gh, docker-cli (via socket)

# Additional packages from apt — includes podman/buildah/skopeo for
# native OCI image workflows alongside the Docker CLI compatibility
RUN apt-get update && apt-get install -y --no-install-recommends \
    podman \
    buildah \
    skopeo \
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

# Create workspace directory for cloning repos
RUN mkdir -p /workspace && chown vscode:vscode /workspace
WORKDIR /workspace