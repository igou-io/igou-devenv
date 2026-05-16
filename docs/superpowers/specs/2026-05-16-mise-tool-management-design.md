# Mise-managed CLI tool installation

**Issue:** [#44](https://github.com/igou-io/igou-devenv/issues/44) — Approach A
**Status:** Design
**Date:** 2026-05-16

## Problem

After PR #43 landed cryptographic verification for every binary in the image, three Dockerfiles (`.devcontainer/Dockerfile`, `builds/podman-rootful/Dockerfile`, `builds/podman-socket/Dockerfile`) each contain ~700 lines of per-tool verification logic for the same 20 tools. Per-upstream quirks (Helm `.asc` on GitHub vs tarball on get.helm.sh, Red Hat inline-signed not detached, sops format change between v3.12.2 → v3.13.0) drove 9 CI iterations on the original PR. That maintenance burden scales linearly with tool count and changes underneath us on every minor upstream pivot. The triplication across three Dockerfiles is the H6 drift risk.

## Goals

- Replace per-tool inline verification logic with a single declarative manifest (`mise.toml`) shared across all three Dockerfiles
- Eliminate H6 drift: tool versions and verification methods become impossible to diverge between dev and podman builds
- Strengthen supply-chain posture: pin per-asset checksums in a lockfile (closes a gap today's TOFU model doesn't address), enforce a release-age gate uniformly, and make verification-method downgrades detectable
- Reduce TOFU bootstrap surface from 7 binaries (cosign, slsa-verifier, virtctl, direnv, age, Cursor, opencode) to 3 (mise, Cursor, opencode)
- Remove ~125MB of verifier tooling (cosign + slsa-verifier + standalone gpg keyrings) from the runtime image

## Non-goals

- Migrating Cursor and opencode to mise. Their distribution model (date-versioned URLs, manual SHA capture, no GitHub release asset format) doesn't fit aqua's package model cleanly. Their existing release-age gate is strong; leave them inline.
- Migrating Claude Code to mise. The Anthropic-PGP-verified install is a strong design we don't replace.
- Migrating Python deps to uv. Worth doing as a clean follow-up (see "Future direction" below) but stacking it on this refactor inflates the review surface.
- Replacing the Makefile with mise tasks. The Makefile is short and well-known; adding a second task runner doubles the conceptual surface for new contributors.
- Replacing `use`/`unuse` 1Password env-switching with mise `[env]`. Already documented in ADR-0001; switching is churn for no clear win.

## Architecture

A single `mise.toml` at the repo root becomes the canonical tool manifest for all three Dockerfiles. Each Dockerfile bootstraps `mise` via TOFU SHA256 (the same chicken-and-egg trust anchor we already have for `cosign`), then runs `mise install --yes` against that shared manifest. Mise consumes the upstream aqua-registry to know how to verify each tool, with the registry pinned to a specific git SHA via `aqua.registry_url`.

Four tools that aren't in upstream aqua-registry (`oc`, `virtctl`, `kube-burner`, `kube-burner-ocp`) get custom packages in a new `aqua-registry/` directory at the repo root. The exact integration mechanism — Mise's aqua overlay (if supported), Mise's `http` backend with per-platform SHA pinned via `mise.lock`, or a small custom plugin — is determined during plan-writing based on which approach can express the verification requirements (notably `oc`'s inline-signed `sha256sum.txt.gpg` against Red Hat key 2). The design constraint is: each off-registry tool MUST resolve to a verification method at least as strong as today's inline install. Cursor, opencode, and Claude Code stay as inline installs.

`mise.lock` is committed to the repo with `lockfile_platforms = ["linux-x64", "linux-arm64"]`, and `locked = true` makes builds fail closed if any URL/checksum drifts. After install, a sweep symlinks `~/.local/share/mise/installs/*/*/bin/*` into `/usr/local/bin/` so tools are on PATH without shell activation.

### Trust anchors

| Anchor | Today | After |
|---|---|---|
| TOFU SHA256 binaries | cosign, slsa-verifier, virtctl, direnv, age, Cursor, opencode | **mise**, Cursor, opencode |
| Upstream verification keys/identities | 7 distinct (Helm GPG, HashiCorp GPG, Red Hat GPG, fluxcd cosign, getsops cosign, argocd SLSA, Anthropic GPG) | Same 7, but pinned in aqua-registry@SHA + 4 overlay packages |
| New trust anchor introduced | — | aqua-registry@SHA (Renovate-bumped, PR-reviewed, audit-tested) |

Net change: TOFU bootstrap drops from 7 binaries to 3. Per-tool verification logic moves from ~700 lines × 3 Dockerfiles to one shared `mise.toml` + 4 small YAML overlay packages.

## Components

**1. `mise.toml` (repo root)** — single source of truth for the 17 standard tools (kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, rclone, direnv, age, node) plus 4 overlay tools (oc, virtctl, kube-burner, kube-burner-ocp). Top of file declares `[settings]` (paranoid, locked, minimum_release_age, lockfile_platforms, aqua.registry_url pinned to SHA). Renovate's native `mise` manager bumps versions in this file.

**2. `mise.lock` (repo root, committed)** — per-platform asset URLs and SHA256s for the two architectures we build for (linux-x64, linux-arm64). Regenerated by running `mise install` locally after a version bump, committed alongside the bump. CI installs use it as-is and fail if anything resolves differently.

**3. `aqua-registry/` (repo root, new directory)** — custom packages for the 4 off-registry tools. Each package declares the asset URL template, per-platform SHA256 (in `mise.lock`), and the strongest verification the upstream supports (kube-burner: SHA256 only; oc: Red Hat GPG-signed `sha256sum.txt.gpg`; virtctl: SHA256 only — same as today's inline install). The integration shape (aqua overlay vs http backend vs custom plugin) is selected during plan-writing; this spec only constrains the per-tool verification floor.

**4. `tests/test-mise.sh` (new — verification audit)** — the H6 enforcement layer. Runs inside the built container.
- Asserts `mise --version` matches the pinned bootstrap version (catches a corrupted bootstrap).
- Runs `mise install --dry-run --verbose` and parses the output.
- For each tool in `mise.toml`, looks up the expected verification method in `tests/mise-expected-verification.toml`.
- Fails if any tool resolved to weaker verification than expected, or if any tool is missing from the manifest (forces reviewer to make a conscious decision when adding a new tool).
- Bonus assertion: every binary mise installed actually exists at `/usr/local/bin/<tool>` and runs `--version` successfully.

**5. `tests/test-mise-lockfile.sh` (new — lockfile freshness)** — runs on the host (or in CI), not in the container.
- `mise install --dry-run` against a clean cache directory; compares against committed `mise.lock`.
- Fails if `mise.toml` has a version that isn't reflected in `mise.lock`, or if `mise.lock` has stale entries for tools no longer in `mise.toml`.
- Catches the "hand-edited mise.toml without regenerating lockfile" failure mode at PR time, not at build time.

**6. `tests/mise-expected-verification.toml` (new)** — the canonical record of what verification method each tool MUST use. Encodes the audit knowledge from H3 once.

**7. Dockerfile changes (×3)** — each Dockerfile gets the same shape:
1. Pinned mise bootstrap block (TOFU SHA256 for amd64/arm64).
2. `COPY mise.toml mise.lock /etc/mise/`
3. `COPY aqua-registry/ /etc/mise/aqua-registry/`
4. Set `MISE_GLOBAL_CONFIG_FILE`, `MISE_DATA_DIR=/opt/mise`, `MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml` env vars.
5. `RUN mise install --yes`.
6. Symlink sweep: `find /opt/mise/installs -type f -executable -path '*/bin/*' -exec ln -sf {} /usr/local/bin/ \;`.

The three Dockerfiles diverge only in: base image, OS-package list, user/group names. The tool-install section becomes byte-identical.

**8. `tests/test-tools.sh` (modified)** — already exists. Per-tool version checks (`kubectl version --client`, etc.) are removed — they're redundant once `test-mise.sh` confirms each binary launches successfully. What stays: tests for OS-package tools (jq, podman, etc.) and Python packages (Ansible, etc.) — those aren't managed by mise.

**9. Renovate updates (`renovate.json`)** — drop the `customManagers` regex blocks that match `*_VERSION` in Dockerfiles for tools now in `mise.toml`. Add a `packageRules` entry routing `mise` updates into the existing "cli tools" group. Mise itself gets its own group ("mise itself" — a separate trust-anchor concern). Renovate has native support for `mise.toml` and for the aqua-registry SHA via a `customManagers` regex on `aqua.registry_url`. The Dockerfile regex managers stay for Cursor/opencode/Claude Code/mise-bootstrap-SHA which remain inline.

**10. Removed from all three Dockerfiles** — cosign/slsa-verifier installs (saving ~125MB), all 17 standard tool ARG/RUN blocks, the standalone gpg keyrings used only for tool verification. `gpg2` (the dnf/apt package) stays for 1Password rpm verification. Cursor, opencode, Claude Code keep their existing inline installs.

**11. `Makefile` additions** — `make mise-lock` regenerates `mise.lock` after a manual version bump. Documented in CLAUDE.md.

**12. `CLAUDE.md` updates** — new "Tool installation layers" entry under the existing table, documenting that mise.toml is now the source of truth for the 17+4 tools.

### Files touched

**New:**
- `mise.toml`
- `mise.lock`
- `aqua-registry/` — 4 custom packages for oc, virtctl, kube-burner, kube-burner-ocp (exact file layout selected during plan-writing)
- `tests/test-mise.sh`
- `tests/test-mise-lockfile.sh`
- `tests/mise-expected-verification.toml`

**Modified:**
- `.devcontainer/Dockerfile`
- `builds/podman-rootful/Dockerfile`
- `builds/podman-socket/Dockerfile`
- `renovate.json`
- `tests/test-tools.sh`
- `tests/run-all.sh`
- `Makefile`
- `CLAUDE.md`

## Data flow

### Build time (per Dockerfile)

```
1. FROM <base image>
2. Install OS packages (apt/dnf), 1Password rpm, Docker CLI rpm    ← unchanged
3. Bootstrap mise:
     curl mise-${VER}-linux-${ARCH}.tar.gz
     sha256sum -c against pinned SHA   ← TOFU anchor
     extract to /usr/local/bin/mise
4. COPY mise.toml mise.lock /etc/mise/
   COPY aqua-registry/ /etc/mise/aqua-registry/
   ENV MISE_DATA_DIR=/opt/mise
       MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml
       MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml
5. RUN mise install --yes        ← see "install-time flow" below
6. RUN find /opt/mise/installs -type f -executable -path '*/bin/*' \
        -exec ln -sf {} /usr/local/bin/ \;
7. Install Cursor agent + opencode (existing inline blocks, unchanged)
8. Install Claude Code (existing inline block, unchanged)
```

### Install-time flow (inside `mise install --yes`, per tool)

```
For each tool in mise.toml:
  1. Look up package metadata in /etc/mise/aqua-registry/ (overlay)
       └─ fallback to mise's bundled aqua-registry @ pinned SHA
  2. Check mise.lock for pre-resolved URL + SHA256 for current platform
       └─ locked=true: fail if missing
  3. Check minimum_release_age (10d):
       └─ fail if version published < 10 days ago
  4. Download asset from locked URL
  5. Verify SHA256 against locked checksum
  6. Run registry-declared verification:
       SLSA           → verify .intoto.jsonl matches source-uri + tag
       cosign keyless → verify cert identity + OIDC issuer
       GPG            → verify .asc against registry-pinned fingerprint
       SHA-only       → already done in step 5
  7. paranoid=true: re-run provenance check after extraction
  8. Install to /opt/mise/installs/<tool>/<version>/bin/<tool>
```

### Test-time flow (`tests/test-mise.sh`)

```
1. Start container (podman run --rm <image>)
2. Run `mise install --dry-run --verbose 2>&1 | tee /tmp/mise.log`
3. For each line `tool=X verifier=Y`:
     read expected from tests/mise-expected-verification.toml
     fail if Y != expected
4. Confirm no tool resolved to "none" or "checksum-only" unless explicitly allowed
5. Run `<tool> --version` for every tool in mise.toml; fail if any errors
```

### Renovate update flow

```
1. Renovate scans mise.toml via native manager
2. PR opened: tool version bump in mise.toml
3. CI runs `mise install --yes` against the bumped manifest
     └─ resolves new URLs/checksums, updates mise.lock
4. Renovate's postUpgradeTasks regenerates mise.lock
5. PR includes mise.toml + mise.lock changes
6. Reviewer sees both — version bump AND the new SHA it resolved to
```

### Local developer flow when bumping a tool version

```
1. Edit mise.toml (or accept Renovate PR)
2. make mise-lock              # regenerates mise.lock
3. make test                   # confirms verification methods unchanged
4. Commit mise.toml + mise.lock together
```

## Error handling

The interesting failure modes are about *what mise does when verification breaks*. Default behavior is fail-closed; we layer additional guards on top.

| Failure mode | Mise's default | Our config | Resulting behavior |
|---|---|---|---|
| Tool's SHA256 doesn't match lockfile | Fail install | `locked=true` | Build fails. Forces a deliberate `mise install` + lockfile commit to acknowledge the change. |
| New tool added to mise.toml without lockfile entry | Allow + resolve fresh | `locked=true` | Build fails until contributor runs `make mise-lock` locally and commits. |
| Cosign signature missing/invalid | Fail install | (default) | Build fails. |
| SLSA provenance fails | Fail install | (default) | Build fails. |
| GPG fingerprint doesn't match registry-pinned anchor | Fail install | (default) | Build fails. |
| aqua-registry silently changes a tool's verifier (e.g., argocd SLSA → SHA-only) | Install succeeds | `tests/test-mise.sh` audit | `make test` fails — manifest expected SLSA, registry now says SHA. Forces a conscious update. |
| Tool published < 10 days ago | Allow | `minimum_release_age=10d` | Build fails with explicit "wait or override" message. Override via `MISE_MINIMUM_RELEASE_AGE=0` build arg. |
| Mise itself's TOFU SHA256 fails | (curl-and-check) | Pinned SHA per arch | Bootstrap step fails. Same model as today's cosign bootstrap. |
| Tool's upstream URL 404s (CDN gone) | Fail install | — | Build fails. Lockfile still has the URL — could fall back to a mirror via `MISE_*_FORCE_DOWNLOAD_URL` env. |
| aqua-registry SHA pin gets bumped | (just runs) | PR review + CI test | The verification-audit test re-runs against the new registry SHA. If anything degraded, test fails. |
| Hand-edited mise.toml without regenerating mise.lock | (build fails late) | `tests/test-mise-lockfile.sh` | PR fails before reaching the build step. |
| Workspace-mounted malicious mise.toml at container runtime | (would be loaded) | `MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml` | Mise refuses to read any other config path. |

Two failure modes worth calling out specifically because they're new:

**Lockfile drift on PRs not touched by Renovate.** If someone hand-edits a tool version in `mise.toml` without regenerating `mise.lock`, the build fails fast. `make mise-lock` documented in CLAUDE.md, and `tests/test-mise-lockfile.sh` catches it at PR time.

**aqua-registry going stale.** If we pin to an old SHA for too long, new tool versions may need newer registry config (e.g., a tool changes its release asset naming). Renovate bumps the SHA on a regular cadence; the verification-audit test acts as a safety net for what the bump changed.

## Testing

Three layers, mirroring the existing `tests/` structure:

**1. `tests/test-mise.sh`** (described under Components) — verification audit, runs in-container.

**2. `tests/test-tools.sh`** — modified to drop now-redundant per-tool `--version` checks; keeps OS-package and Python tests.

**3. `tests/test-mise-lockfile.sh`** — lockfile freshness check, runs on host.

**Wired into:**
- `tests/run-all.sh` gains both new tests
- `make test` (already an alias for `run-all.sh`) picks them up automatically
- `make e2e` runs them after the rebuild
- The existing GitHub Actions workflow (`.github/workflows/build.yaml`) already invokes the test suite — no workflow changes needed beyond what `make test` covers

### Example `tests/mise-expected-verification.toml`

```toml
# What verification method we EXPECT each tool to use.
# If aqua-registry silently downgrades any of these, test-mise.sh fails.
kubectl       = "sha256"            # dl.k8s.io publishes per-binary .sha256
helm          = "gpg"               # Helm release-signing key
terraform     = "gpg"               # HashiCorp release key
gh            = "sha256"
argocd        = "slsa"              # SLSA L3 attestation
kustomize     = "sha256"
kubeseal      = "sha256"
flux2         = "cosign-keyless"
sops          = "cosign-keyless"
kubeconform   = "sha256"
kind          = "sha256"
act           = "sha256"
tkn           = "sha256"
rclone        = "sha256"
direnv        = "sha256"
age           = "sha256"
node          = "sha256"
oc            = "gpg"               # Red Hat key 2 (custom overlay package)
virtctl       = "sha256"            # custom overlay package, no upstream sig
kube-burner   = "sha256"            # custom overlay package
kube-burner-ocp = "sha256"          # custom overlay package
```

That manifest IS the audit-trail artifact from H3. The 9 CI iterations of PR #43 produced this knowledge — we encode it once here and Mise + the audit test together enforce it forever after.

## Supply-chain mitigations summary

| Threat | Mitigation in this design |
|---|---|
| Compromised upstream tool publisher | Per-tool cryptographic verification (SLSA/cosign/GPG/SHA) enforced by aqua-registry config + `paranoid=true` |
| Compromised aqua-registry | Pinned to specific git SHA (Renovate-bumped, PR-reviewed) + `tests/test-mise.sh` audit catches verification downgrades |
| Compromised mise itself | TOFU SHA256 bootstrap (same model as today's cosign bootstrap) — single TOFU anchor instead of seven |
| Compromised CDN serving different bytes at the same version | `mise.lock` pins per-asset SHA256 + `locked=true` fails closed |
| Newly-published malicious version (xz-style) | `minimum_release_age = "10d"` blocks any release younger than 10 days |
| Hand-edited mise.toml without lockfile update | `tests/test-mise-lockfile.sh` fails the PR |
| Workspace-mounted malicious mise.toml at runtime | `MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml` allowlist |
| Build cache poisoning (mise's own cache dir) | `MISE_DATA_DIR=/opt/mise` is a build-stage path; runtime image inherits but doesn't write |

Net change vs today: **stronger** on most axes (lockfile + minimum-release-age are net-new defenses), **same** on per-tool verification (we keep the cryptographic checks, just stop hand-rolling them), **one new trust anchor** (aqua-registry maintainers, mitigated by SHA pinning + audit test).

## Future direction: uv via mise (out of scope here)

The current `requirements.txt` pins 14 direct Python deps with `==`, but pip resolves transitive deps fresh on every build. `paramiko`, `kubernetes`, and the Ansible packages each pull in dozens of transitive deps. A compromised transitive (`requests`, `cryptography`, anything in the dep tree) would slip in silently because nothing is pinned or hash-verified.

A clean follow-up after this refactor lands: migrate the `pip install` step to `uv sync --locked` against a `uv.lock` with hashes. Benefits aligned with the priorities of this design:

- **Transitive dependency pinning + hash verification.** `uv.lock` pins every transitive dep with SHA256. Closes a real gap that the current setup doesn't address. Same supply-chain win as `mise.lock` for binaries, applied to Python.
- **uv installed by mise.** uv is in aqua-registry with cosign-keyless verification — joins the same supply-chain story as the binaries. No new TOFU bootstrap.
- **Renovate native `uv.lock` support.** Same flow as `mise.toml` + `mise.lock`.

Estimated effort: ~1 day, mechanical. Why not now: stacking on this refactor inflates review surface and makes regressions harder to bisect. Worth a separate issue once Mise lands.

Caveat: `ansible-builder` and `ansible-runner` shell out to `pip` at runtime to install collections inside execution environments. uv replaces *our* use of pip for the build-time install; pip stays on PATH for Ansible's internal use.

## Mise features explicitly considered and deferred

These have potential but aren't part of the initial refactor — captured here so they aren't re-litigated:

- **Mise tasks → Makefile replacement.** Mise has `[tasks]` with parallel execution, change detection, file-watching. Could absorb `make renovate-validate`, `make renovate-dry-run`, test-runner targets. Deferred: Makefile is short and well-known; adding a second task runner doubles conceptual surface for new contributors. Re-evaluate if Makefile grows.
- **Mise `[env]` → `use`/`unuse` 1Password env-switching replacement.** Mise can source env vars from `op` directly. Deferred: existing pattern is documented in ADR-0001 and works; switching is churn for no clear win.
- **Per-workspace `mise.toml` in target repos** (igou-kubernetes, igou-ansible). Each repo could pin its own kubectl/helm versions. Genuinely useful long-term — gets reproducible tool versions per-repo independent of the devcontainer image's age. Out of scope for this refactor; a separate cross-repo initiative.

## Open questions

**Off-registry tool integration mechanism.** The spec constrains the verification floor for each off-registry tool but defers the choice between (a) Mise aqua overlay (cleanest if Mise's aqua backend supports a local-directory overlay on top of the upstream registry), (b) Mise's `http` backend with per-platform SHA pinning in `mise.lock` (works universally but harder to express GPG verification for `oc`), or (c) a small custom plugin (most flexible, most code). The plan-writing phase should resolve this by reading the actual Mise aqua-backend source/docs and prototyping `oc`'s GPG path specifically.
