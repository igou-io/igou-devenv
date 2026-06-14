# Weekly CalVer release pipeline — design

- **Date:** 2026-06-14
- **Status:** Approved (brainstorming), pending implementation plan
- **Repo:** `igou-io/igou-devenv`

## Problem / context

Renovate (hosted Mend app) runs Sunday (`before 11pm on sunday`, UTC) and
auto-merges most dependency updates. Two things are not fully hands-off:

1. The grouped **mise-tools PR** can't auto-merge — the hosted app can't
   regenerate `mise.lock` (no `postUpgradeTasks`), so the PR is stale and fails
   CI (`mise-lockfile-check` + the build's locked `mise install`). Today a human
   runs `make mise-lock` + push (Approach 3).
2. There is no **release artifact** per week — `latest` floats at the tip of
   `main`, with no dated, immutable snapshot or changelog.

This design adds a **weekly Monday CalVer release** that (a) finishes the mise
PR by regenerating its lock so it merges, and (b) cuts a dated release of the
week's accumulated updates.

The mise binary itself is already verified via GPG-signed checksums (no
per-version SHA), so mise *binary* bumps remain fully automated and need no
involvement here.

## Goals

- Eliminate the weekly manual `make mise-lock` step.
- Produce a dated, immutable weekly release: CalVer-tagged image + git tag +
  GitHub Release with notes and SBOM.
- Keep the supply-chain posture: lockfile stays authoritative; the ≥10-day
  stability window is preserved.
- No broken `latest`: a bad weekly bump must not ship.

## Non-goals

- Replacing the hosted Renovate app (it keeps proposing all updates).
- Reimplementing version discovery / stability windows (Renovate already does
  this across mise's heterogeneous backends).
- Releasing more often than weekly.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Pipeline scope | **Hybrid (Z)** — Renovate *proposes* mise versions (keeps its `mise` manager + `minimumReleaseAge: 10d`); the pipeline owns the **lock + release**. |
| Release artifact | CalVer image (`:YYYY.MM.DD` + `:latest`) **+** git tag `vYYYY.MM.DD` **+** GitHub Release (auto notes + SBOM). |
| Merge model | Open/keep a PR (Renovate's mise PR); the prepare job pushes the lock, waits for green, merges. |
| Stability window | `N = 10` days, kept in Renovate config (unchanged). |
| CalVer format | `YYYY.MM.DD` (e.g. `2026.06.15`); git tag `vYYYY.MM.DD`. |
| Schedule (UTC) | `release-prepare` Mon **06:30**, `release` Mon **08:00**. |
| Merge mechanism | Job-poll-then-merge with `RELEASE_PAT` (repo has `allow_auto_merge: false`, `main` unprotected — GitHub-native auto-merge is not used). |

## Architecture

Three pieces; only two are new.

### 1. Renovate (Sunday) — unchanged
Keeps all managers including `mise`, `automerge: true`, `minimumReleaseAge: 10d`.
Non-mise PRs (base image, GitHub Actions, Python, mise binary) auto-merge to
`main` on green, as today. The grouped `renovate/mise-managed-cli-tools` PR
opens but stays red (stale lock) — handled by the prepare job below.

### 2. `.github/workflows/release-prepare.yml` (new) — cron Mon 06:30 UTC
Finishes the mise PR so it can merge.

```
trigger: schedule (Mon 06:30 UTC) + workflow_dispatch
steps:
  1. checkout main with RELEASE_PAT
  2. find the open PR with head branch "renovate/mise-managed-cli-tools"
     - none open  -> log "no mise updates this week", exit 0
  3. checkout that PR branch
  4. export GITHUB_TOKEN; run `make mise-lock`
     - on failure (e.g. a version yanked) -> open/update a tracking issue, exit 1
  5. if mise.lock changed: commit + push to the PR branch with RELEASE_PAT
     (a PAT push re-triggers build.yaml + mise-lockfile-check; GITHUB_TOKEN would not)
  6. wait for the PR's `build` check to succeed (`gh pr checks <pr> --watch`)
     - on red -> open/update a tracking issue, exit 1 (PR stays open for a human)
  7. merge the PR: `gh pr merge <pr> --squash --delete-branch` (RELEASE_PAT)
```

Failure here never blocks the release: a broken mise bump leaves its PR open +
an issue filed; the 08:00 release still ships the rest of the week's updates.

### 3. `.github/workflows/release.yml` (new) — cron Mon 08:00 UTC
Cuts the dated release from whatever is on `main`.

```
trigger: schedule (Mon 08:00 UTC) + workflow_dispatch (with `dry_run` input)
permissions: contents: write, packages: write
steps:
  1. checkout main
  2. VERSION=$(date -u +%Y.%m.%d)        # provided via workflow env at runtime, not committed
  3. if tag vVERSION already exists       -> exit 0 (idempotent re-run guard)
     if main has not advanced since the latest v* tag -> exit 0 (nothing to release)
  4. build + test the devcontainer (devcontainers/ci, runCmd tests/run-all.sh)
  5. publish image ghcr.io/igou-io/igou-devenv:$VERSION and :latest
  6. generate SBOM (existing anchore/sbom-action step)
  7. push git tag v$VERSION
  8. create GitHub Release v$VERSION:
       - auto-generated notes (merged PRs since the previous tag)
       - attach the SBOM artifact
  dry_run=true: do steps 1-4 only (build+test), skip 5-8
```

`:latest` continues to be published by the existing `build.yaml` on every push
to `main`; `release.yml` adds the immutable `:YYYY.MM.DD` tag + Release.

## Versioning

- Image tags: `ghcr.io/igou-io/igou-devenv:2026.06.15` and `:latest`.
- Git tag: `v2026.06.15`.
- The CalVer value is computed at run time (`date -u +%Y.%m.%d`); it is never
  committed to a file (avoids the harness's no-`Date.now()`-in-scripts concern
  and keeps the repo free of a version-bump commit).

## Prerequisites

- **`RELEASE_PAT`** repo secret — fine-grained PAT on `igou-io/igou-devenv`
  with **Contents: read/write** + **Pull requests: read/write** (classic
  equivalent: `repo`). Required because the prepare job's lock push must
  re-trigger CI and it merges the PR. *(Provisioned 2026-06-14.)*
- No repo-settings changes required (`main` unprotected, `allow_auto_merge`
  off → job-poll-then-merge). Optional hardening: enable "Allow auto-merge" +
  branch-protect `main` requiring the `build` check.
- Runner has `podman` (ubuntu-latest) — already relied on by `make mise-lock`.

## Failure handling & edge cases

- **mise bump breaks the build / lock regen fails** → PR stays open, tracking
  issue filed; `release.yml` still ships the good (non-mise) updates. Human
  fixes the PR; it rides the next weekly release.
- **No updates this week** (`main` unchanged since last tag) → `release.yml`
  skips; no empty release.
- **Idempotent** → today's `vYYYY.MM.DD` tag already present → skip.
- **No open mise PR** → prepare job is a no-op; release proceeds normally.

## Testing

- Both workflows are `workflow_dispatch`-able. `release.yaml` has `dry_run`
  (build + test only; no tag/publish/release), `version` (tag override), and
  `force` (bypass the skip guards) inputs — for safe manual validation and
  on-demand test releases without waiting for Monday. Note: `workflow_dispatch`
  is only registered once the workflow is on the default branch, so these run
  post-merge.
- `release-prepare.yml` validated against a real (or hand-created) mise PR:
  confirm lock regenerated, pushed, build watched, PR merged.
- `make mise-lock` + `tests/test-mise-lockfile.sh` mechanics already verified in
  CI (`mise-lockfile-check`).

## Out of scope / future

- Retag-instead-of-rebuild in `release.yml` (copy the just-built `latest`
  digest to the CalVer tag) to avoid the second Monday build — an optimization;
  the spec rebuilds for determinism.
- GitHub App token instead of a PAT (more secure; more setup).
- Branch protection / native auto-merge hardening.
