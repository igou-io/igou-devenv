# shellcheck shell=bash
# Sourced by ~/.bashrc for EVERY shell (interactive and not), so agent tool calls
# and scripts get these functions too. Keep it free of prompt/tty assumptions.

# GitHub App tokens (ghapp) — the default path for GitHub auth, replacing the
# static-PAT `use claude-*-github-token` flow. Three ways to authenticate:
#   1. Plain `git` over HTTPS just works — the ghapp credential helper (baked into
#      /etc/gitconfig) mints a contents:write token for exactly the pushed repo.
#   2. `gh-app --repo OWNER/REPO -- <args>`  runs `gh` with a repo-scoped token in
#      GH_TOKEN, nothing exported into your shell.
#   3. `ght OWNER/REPO [perm=level ...]`  exports a fresh repo-scoped GH_TOKEN into
#      the CURRENT shell (for tools that read GH_TOKEN and can't use gh-app).
# App tokens are per-repository by design, so there is no org-wide GH_TOKEN — pass
# the repo. `ght-unset` clears it. Both orgs (david-igou, igou-io) resolve from the
# single App config; the owner half of OWNER/REPO selects the installation.
ght() {
    if [ -z "${1:-}" ]; then
        echo "usage: ght OWNER/REPO [perm=level ...]" >&2
        echo "  e.g. ght igou-io/igou-devenv            (default permissions)" >&2
        echo "       ght david-igou/hermes contents=read" >&2
        return 2
    fi
    local repo="$1"; shift
    local perm_args=() p
    for p in "$@"; do perm_args+=(--permission "$p"); done
    local tok
    tok=$(ghapp token --repo "$repo" "${perm_args[@]}") || {
        echo "ght: failed to mint a token for $repo" >&2
        return 1
    }
    export GH_TOKEN="$tok" GITHUB_TOKEN="$tok" GHT_REPO="$repo"
    echo "GH_TOKEN minted for $repo (repo-scoped, expires <1h)"
}
ght-unset() {
    unset GH_TOKEN GITHUB_TOKEN GHT_REPO
    echo "GH_TOKEN cleared"
}
