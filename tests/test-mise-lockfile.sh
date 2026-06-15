#!/usr/bin/env bash
# Lockfile freshness: fail if mise.toml has a tool/version not reflected
# in mise.lock, or if mise.lock has stale entries for tools no longer in
# mise.toml. Catches "hand-edited mise.toml without regenerating lockfile"
# at PR time, before the build step.
#
# Uses mise on PATH if available (it's installed in the devcontainer and on CI
# runners); otherwise falls back to a one-shot podman/mise container (same
# mechanism as `make mise-lock`, run inside the devcontainer or in CI).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "${REPO}/mise.toml" "${WORK}/mise.toml"
cp "${REPO}/mise.lock" "${WORK}/mise.lock"

run_mise_dryrun() {
    # `mise install --dry-run` with locked=true (set in mise.toml) refuses
    # to proceed if any tool is missing a lockfile entry. That refusal is
    # exactly the assertion we want — if it succeeds, the lockfile is
    # fresh. We never actually install anything.
    if command -v mise >/dev/null 2>&1; then
        env -i HOME="$WORK" PATH="$PATH" \
            MISE_GLOBAL_CONFIG_FILE="${WORK}/mise.toml" \
            MISE_TRUSTED_CONFIG_PATHS="${WORK}" \
            MISE_DATA_DIR="${WORK}/data" \
            mise install --dry-run 2>&1
    elif command -v podman >/dev/null 2>&1; then
        # Same trick as `make mise-lock`: run mise inside a container.
        # Remove the image's baked-in /mise/config.toml so it does not
        # collide with ours.
        podman run --rm --entrypoint sh \
            -v "${WORK}:/work" \
            -v "${REPO}/aqua-registry:/etc/mise/aqua-registry:ro" \
            -w /work \
            -e MISE_GLOBAL_CONFIG_FILE=/work/mise.toml \
            -e MISE_TRUSTED_CONFIG_PATHS=/work \
            -e GITHUB_TOKEN \
            ghcr.io/jdx/mise:latest -c '
                rm -f /mise/config.toml
                mise trust --quiet --all >/dev/null 2>&1 || true
                mise install --dry-run
            ' 2>&1
    else
        echo "__SKIP__"
    fi
}

OUTPUT="$(run_mise_dryrun)"
RC=$?

if [ "$OUTPUT" = "__SKIP__" ]; then
    echo "[skip] neither mise nor podman on PATH; cannot verify lockfile freshness"
    exit 0
fi

if [ $RC -eq 0 ]; then
    echo "[OK] mise.lock is in sync with mise.toml"
    exit 0
else
    echo "[FAIL] mise.lock is stale — run 'make mise-lock' and commit the result"
    echo "--- mise output ---"
    echo "$OUTPUT"
    exit 1
fi
