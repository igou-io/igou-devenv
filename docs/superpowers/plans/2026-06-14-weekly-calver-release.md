# Weekly CalVer Release Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a weekly Monday pipeline that regenerates the mise lockfile to merge Renovate's mise PR, then cuts a dated CalVer release (image + git tag + GitHub Release).

**Architecture:** Hybrid — hosted Renovate keeps proposing mise versions (min-age 10d). A `release-prepare` workflow (Mon 06:30 UTC) locks + merges the mise PR using `RELEASE_PAT`; a `release` workflow (Mon 08:00 UTC) builds, publishes `:YYYY.MM.DD` + `:latest`, tags `vYYYY.MM.DD`, and creates a GitHub Release. Non-mise logic is extracted into `bin/release-prepare-mise` per the repo's no-embedded-scripts rule.

**Tech Stack:** GitHub Actions, bash, `gh` CLI, `make mise-lock` (podman + `ghcr.io/jdx/mise`), `devcontainers/ci`, `anchore/sbom-action`.

**Spec:** `docs/superpowers/specs/2026-06-14-weekly-calver-release-design.md`

**Prerequisite (already provisioned):** `RELEASE_PAT` secret — fine-grained PAT on `igou-io/igou-devenv` with Contents: read/write + Pull requests: read/write.

**Branch:** `feat/weekly-calver-release` (worktree at `/workspace/_wt/wtcalver`).

---

### Task 1: `bin/release-prepare-mise` script

**Files:**
- Create: `bin/release-prepare-mise`

- [ ] **Step 1: Write the script**

Create `bin/release-prepare-mise`:

```bash
#!/usr/bin/env bash
# Finish the open Renovate mise-tools PR so it can merge: regenerate mise.lock,
# push it (a PAT push re-triggers CI), wait for the build to pass, then
# squash-merge. Hosted Renovate cannot regenerate the lock itself.
#
# Requires (set by the workflow):
#   GH_TOKEN      a token that re-triggers workflows (RELEASE_PAT) — used by gh + git
#   GITHUB_TOKEN  default token — used by `make mise-lock` for GitHub API rate limits
# Also requires: podman, make, gh, git.
set -euo pipefail

REPO="igou-io/igou-devenv"
BRANCH="renovate/mise-managed-cli-tools"

pr="$(gh pr list --repo "$REPO" --state open --head "$BRANCH" --json number --jq '.[0].number // empty')"
if [ -z "$pr" ]; then
  echo "No open mise PR ($BRANCH) — nothing to prepare."
  exit 0
fi
echo "Preparing mise PR #$pr"

gh pr checkout "$pr" --repo "$REPO"

make mise-lock

if git diff --quiet -- mise.lock; then
  echo "mise.lock already in sync; no commit needed."
else
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git commit -am "chore(mise): regenerate mise.lock"
  git push
  # Give GitHub a moment to register the new checks before watching.
  sleep 30
fi

echo "Waiting for checks on PR #$pr to complete..."
gh pr checks "$pr" --repo "$REPO" --watch --interval 30

gh pr merge "$pr" --repo "$REPO" --squash --delete-branch
echo "Merged mise PR #$pr"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/release-prepare-mise`

- [ ] **Step 3: Lint with shellcheck (verify it passes)**

Run: `shellcheck bin/release-prepare-mise`
Expected: no output, exit 0.

- [ ] **Step 4: Syntax-check the script parses**

Run: `bash -n bin/release-prepare-mise`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/release-prepare-mise
git commit -m "feat(ci): bin/release-prepare-mise — lock + merge the weekly mise PR"
```

---

### Task 2: `release-prepare.yaml` workflow

**Files:**
- Create: `.github/workflows/release-prepare.yaml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release-prepare.yaml`:

```yaml
name: release-prepare (weekly mise lock)

# Monday 06:30 UTC (after Renovate's Sunday run). Renovate cannot regenerate
# mise.lock (hosted Mend app, no postUpgradeTasks), so its mise-tools PR is
# stale. This job regenerates the lock, pushes it (which re-triggers CI), waits
# for green, and merges — using RELEASE_PAT so the push actually re-triggers
# workflows (a GITHUB_TOKEN push would not). The 08:00 release.yaml then ships.

on:
  schedule:
    - cron: '30 6 * * 1'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  prepare:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          token: ${{ secrets.RELEASE_PAT }}
          fetch-depth: 0

      - name: Lock and merge the open mise PR
        env:
          GH_TOKEN: ${{ secrets.RELEASE_PAT }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash bin/release-prepare-mise

      - name: File an issue on failure
        if: failure()
        env:
          GH_TOKEN: ${{ secrets.RELEASE_PAT }}
        run: |
          gh issue create --repo igou-io/igou-devenv \
            --title "Weekly mise lock prepare failed ($(date -u +%Y-%m-%d))" \
            --body "release-prepare could not regenerate/merge the mise PR. Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}. Fix manually: \`make mise-lock\` on the renovate/mise-managed-cli-tools branch and push." \
            || true
```

- [ ] **Step 2: Validate YAML parses**

Run:
```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/release-prepare.yaml')); print('jobs:', list(d['jobs']))"
```
Expected: `jobs: ['prepare']`

- [ ] **Step 3: Lint with actionlint if available (optional)**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/release-prepare.yaml || echo "actionlint not installed; skipping"`
Expected: no errors (or skip message).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release-prepare.yaml
git commit -m "feat(ci): release-prepare workflow (Mon 06:30 — lock+merge mise PR)"
```

---

### Task 3: `release.yaml` workflow

**Files:**
- Create: `.github/workflows/release.yaml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yaml`:

```yaml
name: release (weekly CalVer)

# Monday 08:00 UTC. Snapshots whatever is on main (the week's merged Renovate
# updates + the mise PR merged by release-prepare) into a dated release:
# image :YYYY.MM.DD + :latest, git tag vYYYY.MM.DD, and a GitHub Release with
# auto-generated notes + the SBOM. Idempotent; skips weeks with no changes.

on:
  schedule:
    - cron: '0 8 * * 1'
  workflow_dispatch:
    inputs:
      dry_run:
        description: "Build + test only; do not tag/publish/release"
        type: boolean
        default: false

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: 0

      - name: Decide version and whether to release
        id: plan
        run: |
          VERSION="$(date -u +%Y.%m.%d)"
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          if git rev-parse "v$VERSION" >/dev/null 2>&1; then
            echo "Tag v$VERSION already exists — skipping."
            echo "proceed=false" >> "$GITHUB_OUTPUT"; exit 0
          fi
          last="$(git tag --list 'v*' --sort=-creatordate | head -1)"
          if [ -n "$last" ] && [ -z "$(git log "$last"..HEAD --oneline)" ]; then
            echo "main has not advanced since $last — skipping."
            echo "proceed=false" >> "$GITHUB_OUTPUT"; exit 0
          fi
          echo "proceed=true" >> "$GITHUB_OUTPUT"

      - name: Log in to GHCR
        if: steps.plan.outputs.proceed == 'true'
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin

      - name: Build and test devcontainer
        if: steps.plan.outputs.proceed == 'true'
        uses: devcontainers/ci@b63b30de439b47a52267f241112c5b453b673db5 # v0.3
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          push: ${{ inputs.dry_run && 'never' || 'always' }}
          imageName: ghcr.io/igou-io/igou-devenv
          runCmd: /workspace/igou-devenv/tests/run-all.sh

      - name: Tag and push the CalVer image
        if: steps.plan.outputs.proceed == 'true' && inputs.dry_run != true
        run: |
          docker tag  ghcr.io/igou-io/igou-devenv:latest ghcr.io/igou-io/igou-devenv:${{ steps.plan.outputs.version }}
          docker push ghcr.io/igou-io/igou-devenv:${{ steps.plan.outputs.version }}

      - name: Generate SBOM
        if: steps.plan.outputs.proceed == 'true' && inputs.dry_run != true
        uses: anchore/sbom-action@e22c389904149dbc22b58101806040fa8d37a610 # v0
        with:
          image: ghcr.io/igou-io/igou-devenv:${{ steps.plan.outputs.version }}
          artifact-name: devcontainer-sbom-${{ steps.plan.outputs.version }}
          output-file: devcontainer.spdx.json
          format: spdx-json

      - name: Tag and create GitHub Release
        if: steps.plan.outputs.proceed == 'true' && inputs.dry_run != true
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          git tag "v${{ steps.plan.outputs.version }}"
          git push origin "v${{ steps.plan.outputs.version }}"
          gh release create "v${{ steps.plan.outputs.version }}" \
            --repo igou-io/igou-devenv \
            --title "v${{ steps.plan.outputs.version }}" \
            --generate-notes \
            devcontainer.spdx.json
```

- [ ] **Step 2: Validate YAML parses**

Run:
```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/release.yaml')); print('steps:', [s.get('name','uses') for s in d['jobs']['release']['steps']])"
```
Expected: lists the 6 steps (checkout, Decide version…, Log in to GHCR, Build and test…, Tag and push…, Generate SBOM, Tag and create…).

- [ ] **Step 3: Lint with actionlint if available (optional)**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/release.yaml || echo "actionlint not installed; skipping"`
Expected: no errors (or skip message).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yaml
git commit -m "feat(ci): release workflow (Mon 08:00 — CalVer image + tag + Release)"
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md` (architecture tree)
- Modify: `README.md` (release section)

- [ ] **Step 1: Add the two workflows to CLAUDE.md's architecture tree**

In `CLAUDE.md`, find the line:
```
.github/workflows/mise-lockfile-check.yaml  # CI: fails PRs whose mise.lock is stale vs mise.toml
```
Add immediately after it:
```
.github/workflows/release-prepare.yaml  # CI: Mon 06:30 — regenerate mise.lock + merge the mise PR
.github/workflows/release.yaml          # CI: Mon 08:00 — weekly CalVer image + git tag + GitHub Release
```

- [ ] **Step 2: Add a "Weekly release" subsection to CLAUDE.md**

In `CLAUDE.md`, immediately after the `### Bumping a CLI tool version` section (before `## Pre-push Requirements`), add:

```markdown
### Weekly release (CalVer)

Every Monday two scheduled workflows run:

1. `release-prepare.yaml` (06:30 UTC) regenerates `mise.lock` on the open
   Renovate mise PR (`bin/release-prepare-mise`), waits for green, and merges
   it — using `RELEASE_PAT`. If the bump breaks the build it files an issue and
   leaves the PR open; the release still ships the rest.
2. `release.yaml` (08:00 UTC) builds + tests `main`, publishes
   `ghcr.io/igou-io/igou-devenv:YYYY.MM.DD` + `:latest`, pushes tag
   `vYYYY.MM.DD`, and creates a GitHub Release (auto notes + SBOM). Skips weeks
   with no changes; idempotent.

Manual fallback: if `release-prepare` files an issue, regenerate the lock by
hand — `make mise-lock` on the `renovate/mise-managed-cli-tools` branch, then
push; it merges and rides the next weekly release.

Requires the `RELEASE_PAT` repo secret (Contents + Pull-requests: read/write).
```

- [ ] **Step 3: Add a release section to README.md**

In `README.md`, after the dependency-management bullets (the section ending around the `Trust anchors (mise itself, aqua-registry pin)` paragraph), add:

```markdown
### Weekly release

A Monday pipeline cuts a dated release of the devcontainer:

- `release-prepare.yaml` (06:30 UTC) regenerates `mise.lock` to merge the week's
  Renovate mise PR (it can't merge itself — the hosted app can't regenerate the
  lock).
- `release.yaml` (08:00 UTC) publishes `ghcr.io/igou-io/igou-devenv:YYYY.MM.DD` +
  `:latest`, tags `vYYYY.MM.DD`, and creates a GitHub Release with notes + SBOM.

`:latest` always tracks `main`; the `:YYYY.MM.DD` tags are immutable weekly
snapshots to pin or roll back to. Needs the `RELEASE_PAT` secret.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document the weekly CalVer release pipeline"
```

---

### Task 5: Push and integration-validate

**Files:** none (validation only)

> Note: `schedule:` triggers only fire from the **default branch**, so the crons won't run until this merges to `main`. Validate via `workflow_dispatch` on the feature branch first.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/weekly-calver-release
```

- [ ] **Step 2: Open the PR (so build.yaml validates the whole change)**

```bash
gh pr create --repo igou-io/igou-devenv --base main --head feat/weekly-calver-release \
  --title "feat(ci): weekly CalVer release pipeline" \
  --body "Implements docs/superpowers/specs/2026-06-14-weekly-calver-release-design.md. See plan docs/superpowers/plans/2026-06-14-weekly-calver-release.md."
```
Confirm the PR's `build` check passes (workflow/doc-only change; the devcontainer build is unaffected).

- [ ] **Step 3: Dry-run the release workflow from the branch**

```bash
gh workflow run release.yaml --repo igou-io/igou-devenv --ref feat/weekly-calver-release -f dry_run=true
sleep 10
gh run watch "$(gh run list --repo igou-io/igou-devenv --workflow release.yaml --limit 1 --json databaseId --jq '.[0].databaseId')" --repo igou-io/igou-devenv --exit-status --interval 20
```
Expected: success. The build+test runs; the tag/publish/release steps are skipped (dry_run). Confirms the version-guard and build path work.

- [ ] **Step 4: Integration-test release-prepare against a synthetic mise PR**

Create a throwaway PR that looks like Renovate's mise PR, then run the prepare workflow:
```bash
# from a fresh worktree of main:
git worktree add /tmp/synthpr -b renovate/mise-managed-cli-tools origin/main
cd /tmp/synthpr
sed -i 's/^kind = "0.32.0"/kind = "0.33.0"/' mise.toml   # make the lock stale (adjust to a real newer version)
git commit -am "chore(deps): synthetic mise bump for pipeline test"
git push -u origin renovate/mise-managed-cli-tools
gh pr create --repo igou-io/igou-devenv --base main --head renovate/mise-managed-cli-tools \
  --title "TEST synthetic mise bump" --body "pipeline test — will be merged by release-prepare"

gh workflow run release-prepare.yaml --repo igou-io/igou-devenv --ref feat/weekly-calver-release
sleep 10
gh run watch "$(gh run list --repo igou-io/igou-devenv --workflow release-prepare.yaml --limit 1 --json databaseId --jq '.[0].databaseId')" --repo igou-io/igou-devenv --exit-status --interval 30
```
Expected: the workflow regenerates `mise.lock`, pushes it, waits for the build to pass, and merges the synthetic PR. Verify the PR shows MERGED and `mise.toml`/`mise.lock` on `main` reflect the bump.

> If the synthetic bump's version doesn't exist upstream, `make mise-lock` will fail — pick a real newer version (check `mise outdated` or the tool's releases) so the lock can resolve.

- [ ] **Step 5: Clean up the synthetic test and finalize**

```bash
cd /workspace/igou-devenv && git worktree remove /tmp/synthpr --force
```
If the synthetic bump merged to `main`, either keep it (it's a real, valid tool bump) or revert it via a follow-up PR. Then merge the feature PR (Step 2) once its `build` check is green.

- [ ] **Step 6: Post-merge sanity**

After the feature PR merges, confirm the two workflows appear under Actions and are scheduled. The first real cron run is the next Monday; until then they remain `workflow_dispatch`-able.
