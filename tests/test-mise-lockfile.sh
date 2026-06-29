#!/usr/bin/env bash
# Lockfile freshness: fail if mise.toml has a tool/version not reflected
# in mise.lock, or if mise.lock has stale entries for tools no longer in
# mise.toml. Catches "hand-edited mise.toml without regenerating lockfile"
# at PR time, before the build step.
#
# Uses the same MISE_VERSION as the Dockerfile. Do not use arbitrary host mise
# here: lockfile format and http-backend metadata have changed across mise
# releases, and this check must match the version that builds the image.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MISE_VERSION="$(awk -F'"' '/^ARG MISE_VERSION/{print $2; exit}' "${REPO}/.devcontainer/Dockerfile")"
MISE_VERSION="${MISE_VERSION#v}"

run_mise_dryrun() {
    # `mise install --dry-run` with locked=true (set in mise.toml) refuses
    # to proceed if any tool is missing a lockfile entry. That refusal is
    # exactly the assertion we want — if it succeeds, the lockfile is
    # fresh. We never actually install anything.
    "${REPO}/bin/run-pinned-mise" mise install --dry-run 2>&1
}

set +e
OUTPUT="$(run_mise_dryrun)"
RC=$?
set -e

if [ $RC -eq 0 ]; then
    echo "[OK] mise.lock is in sync with mise.toml"
    exit 0
else
    echo "[FAIL] mise.lock is stale — run 'make mise-lock' and commit the result"
    echo "--- mise output ---"
    echo "$OUTPUT"
    exit 1
fi
