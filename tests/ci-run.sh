#!/usr/bin/env bash
# CI test entrypoint, run inside the freshly built image by
# .github/workflows/build.yaml (which builds with `docker buildx` so it can pass
# GITHUB_TOKEN as a BuildKit secret instead of a leaky build ARG). Runs as the
# non-root `igou` user.
#
# The build workflow drives the image directly rather than through the
# devcontainer lifecycle, so we start the dbus + libvirt daemons that
# post-start.sh normally brings up — test-qemu checks their sockets.
# post-start.sh exits early when CI is set, so it runs here with CI unset; the
# suite then runs with CI set so it skips test-env, which needs an interactive
# login shell + .bashrc that CI does not configure.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/../.devcontainer/post-start.sh" || echo "==> post-start.sh exited $? (continuing to tests)"

CI=1 exec "$DIR/run-all.sh"
