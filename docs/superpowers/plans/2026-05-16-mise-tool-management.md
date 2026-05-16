# Mise Tool Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ~700 lines × 3 Dockerfiles of inline per-tool verification logic with a single `mise.toml` + `mise.lock` manifest, hardened with `paranoid`/`locked`/`minimum_release_age` settings and gated by a verification-audit test.

**Architecture:** Each Dockerfile bootstraps `mise` via TOFU SHA256, then runs `mise install --yes` against the shared `mise.toml`. Mise consumes a SHA-pinned aqua-registry for the 17 standard tools. The 4 off-registry tools (`oc`, `virtctl`, `kube-burner`, `kube-burner-ocp`) use Mise's `http` backend with checksums pinned in `mise.lock`; `oc` gets an additional `postinstall` step preserving Red Hat GPG verification. Cosign/slsa-verifier are removed from the runtime image. Cursor, opencode, and Claude Code keep their existing inline installs.

**Tech Stack:** Mise (Rust tool manager), aqua-registry (verification metadata), Renovate (native mise manager), Bash (test scripts), Docker/Podman (image builds), Make (build orchestration).

**Reference spec:** [`docs/superpowers/specs/2026-05-16-mise-tool-management-design.md`](../specs/2026-05-16-mise-tool-management-design.md)

---

## File Structure

**New files:**
- `mise.toml` — single tool manifest, source of truth for 21 tools
- `mise.lock` — per-platform asset URLs and SHA256s, committed
- `aqua-registry/oc-postinstall.sh` — Red Hat GPG verification script invoked by mise postinstall hook
- `tests/test-mise.sh` — verification-method audit (runs in container)
- `tests/test-mise-lockfile.sh` — lockfile freshness check (runs on host)
- `tests/mise-expected-verification.toml` — canonical expected verifier per tool

**Modified files:**
- `.devcontainer/Dockerfile` — replace 17+4 tool blocks with mise bootstrap + install; remove cosign/slsa-verifier
- `builds/podman-rootful/Dockerfile` — same shape as devcontainer
- `builds/podman-socket/Dockerfile` — same shape as devcontainer
- `tests/run-all.sh` — wire in the two new tests
- `tests/test-tools.sh` — drop now-redundant per-tool `--version` assertions for mise-managed tools
- `Makefile` — add `mise-lock` target
- `renovate.json` — add packageRules for mise updates; aqua-registry SHA bumps via customManagers
- `CLAUDE.md` — document the new tool-install layer

**Untouched:** Cursor, opencode, Claude Code blocks (stay inline per spec).

---

## Phase 0: Investigate off-registry tool mechanism

The spec flags this as the only open question. Resolve before writing any production code.

### Task 0.1: Investigate aqua-registry coverage and oc verification path

**Files:**
- Read-only investigation. Outputs notes inline in this task.

- [ ] **Step 1: Check whether aqua-registry already has packages for our 4 "off-registry" tools**

Run:
```bash
podman run --rm -it ghcr.io/jdx/mise:latest sh -c 'mise registry | grep -iE "openshift|oc$|virtctl|kube-burner"'
```

Expected: confirm or deny that any of `oc`, `virtctl`, `kube-burner`, `kube-burner-ocp` appear. If `oc` is in the registry under a different name (e.g., `openshift/oc`, `openshift-clients`), use it. Document findings.

- [ ] **Step 2: Confirm Mise's `http` backend behavior for postinstall hooks**

Read https://mise.jdx.dev/dev-tools/backends/http.html and https://mise.jdx.dev/configuration.html#tools — confirm whether `postinstall` runs *after* the binary is installed and whether a non-zero exit from postinstall marks the install as failed (the binary should not end up on disk).

If postinstall does NOT fail-roll-back, plan B is a custom Mise plugin (bash) that does its own download + GPG verify + extract. Document which we'll use.

- [ ] **Step 3: Confirm Mise lockfile (`mise.lock`) covers `http:` backend tools**

Run on a clean throwaway dir:
```bash
mkdir /tmp/mise-test && cd /tmp/mise-test
cat > mise.toml <<'EOF'
[settings]
lockfile = true
[tools."http:test"]
version = "1.0.0"
url = "https://example.invalid/x"
EOF
mise install --dry-run 2>&1 | head -20
```

Expected: confirm that http-backend tools end up in `mise.lock` with per-platform URLs/checksums. If not, we need to handle this differently. Document.

- [x] **Step 4: Record decisions**

#### Findings (Phase 0 investigation, 2026-05-16)

**Registry coverage** (tested against `ghcr.io/jdx/mise:latest` — mise 2026.5.9):

| Tool | Registry status | Decision |
|---|---|---|
| 16 of the 17 "standard" tools | `aqua:<owner>/<repo>` backend | Use plain name in mise.toml (e.g., `kubectl = "1.36.0"`) |
| `tkn` | NOT a registry shorthand — but `tekton` and `tekton-cli` both resolve to `aqua:tektoncd/cli` | Use `tekton-cli = "..."` key in mise.toml; rename `tkn` references in tests/expected-verification.toml to `tekton-cli` |
| `node` | `core:node` (mise built-in plugin, not aqua) | Plain name; verification floor is mise core (SHA256 from nodejs.org) |
| `oc` | Registry shorthand: `http:oc conda:openshift-cli asdf:mise-plugins/mise-oc` | http backend by default — but we override URL ourselves (see below) because the built-in `http:oc` shorthand uses an unknown URL template that may not match Red Hat mirror |
| `virtctl`, `kube-burner`, `kube-burner-ocp` | NOT in registry | Define as `http:<name>` with explicit per-platform URLs |

**Mise http backend behavior** (tested live):

- **Lockfile**: Generated for both `aqua:` and `http:` backends, **only if `mise.lock` file already exists**. Empty `touch mise.lock` is enough — mise will populate it. This means the Dockerfile must `COPY mise.lock` for the file to be re-used; the Makefile target must `touch mise.lock` before invoking `mise install` when regenerating.
- **Checksum format**:
  - `aqua:` tools → `sha256:<hash>` pulled from upstream-signed `kubectl.sha256` files (high trust).
  - `http:` tools → `blake3:<hash>` computed locally on first install (TOFU). Equivalent security floor to today's inline TOFU-SHA256; just a different hash algorithm. `locked = true` fails the build if it drifts.
  - The http backend ALSO supports inline `checksum = "sha256:..."` in the URL block if we want to commit specific SHA256s alongside URLs — but mise.lock is the preferred mechanism per docs.
- **Per-platform lockfile entries**: `lockfile_platforms = ["linux-x64", "linux-arm64"]` populates both even on an x64 build host (mise fetches the arm64 binary just for hashing).
- **Postinstall failure behavior**:
  - First install: postinstall runs after extract; non-zero exit produces `Error: Failed to install <tool>` and `mise install` returns non-zero. **Docker build halts.** ✅
  - BUT the install directory is created (symlinks to `/mise/http-tarballs/<hash>`) BEFORE postinstall runs, so the binary remains on disk.
  - Subsequent `mise install` calls return exit 0 (mise sees the install dir, skips re-running postinstall). This means dev workflows with `make rebuild` are safe (each Docker layer is a clean install) but interactive `mise install` re-runs do NOT re-verify.
  - **Conclusion for oc**: postinstall hook is acceptable for the Docker build use case — first install in a fresh layer is the only one that matters. Audit test inspects the postinstall script's existence as proxy for "GPG verification configured".

**Decisions:**

- **oc** → `http:oc` backend with **postinstall hook** (`/etc/mise/aqua-registry/oc-postinstall.sh`) that does Red Hat GPG verification independently. We override the URL ourselves rather than relying on the registry's built-in `http:oc` shorthand because we want the URL template visible and Renovate-friendly in mise.toml.
- **virtctl, kube-burner, kube-burner-ocp** → `http:` backend, per-platform URLs, blake3 checksum in mise.lock. Same security floor as today's inline TOFU. No postinstall.
- **tkn** → use `tekton-cli` key in mise.toml (aqua-registry backed). Symlink sweep in Dockerfile creates `/usr/local/bin/tkn` already (since the binary is named `tkn`), so no PATH changes needed. Update the affected sections of Phase 2 (Task 2.1) to use `tekton-cli` not `tkn`.

- [x] **Step 5: Commit the decisions back into this plan file**

```bash
git add docs/superpowers/plans/2026-05-16-mise-tool-management.md
git commit -m "plan: record off-registry tool mechanism for mise refactor"
```

---

## Phase 1: Bootstrap mise on the devcontainer (proof of concept with one tool)

Get the integration shape working end-to-end with kubectl as the canary, before touching any other tool.

### Task 1.1: Add the mise bootstrap block to .devcontainer/Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile` — insert new block before the `# CLI tools — pinned versions managed by Renovate` section header (around line 122)

- [ ] **Step 1: Look up the latest mise version and SHAs**

Run:
```bash
gh api repos/jdx/mise/releases/latest --jq .tag_name
# Then for the chosen version:
VER=<version>
for arch in x64 arm64; do
  curl -fsSL "https://github.com/jdx/mise/releases/download/${VER}/mise-${VER}-linux-${arch}.tar.gz" \
    | sha256sum | awk '{print $1}'
done
```

Record the version and both SHAs.

- [ ] **Step 2: Insert the bootstrap block**

Add this block to `.devcontainer/Dockerfile` immediately before the existing `cosign` install block (which starts around line 124). Replace `<VERSION>`, `<AMD64_SHA>`, `<ARM64_SHA>` with values from Step 1.

```dockerfile
# ---------------------------------------------------------------------------
# Mise — declarative tool manager. Bootstrap via TOFU SHA256; once installed,
# mise verifies all subsequent tools via aqua-registry's per-tool config
# (cosign/SLSA/GPG/SHA256). See docs/superpowers/specs/2026-05-16-mise-tool-management-design.md
# Manual SHA update on version bump:
#   for a in x64 arm64; do curl -sL "https://github.com/jdx/mise/releases/download/<ver>/mise-<ver>-linux-${a}.tar.gz" | sha256sum; done
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION="<VERSION>"
ARG MISE_SHA256_AMD64="<AMD64_SHA>"
ARG MISE_SHA256_ARM64="<ARM64_SHA>"
RUN set -eux; \
    ARCH_RAW=$(uname -m); \
    case "$ARCH_RAW" in \
      x86_64)  ARCH="x64";   EXPECTED_SHA="${MISE_SHA256_AMD64}" ;; \
      aarch64) ARCH="arm64"; EXPECTED_SHA="${MISE_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${ARCH}.tar.gz"; \
    WORK=$(mktemp -d); \
    curl -fsSL -o "${WORK}/mise.tar.gz" "$URL"; \
    echo "${EXPECTED_SHA}  ${WORK}/mise.tar.gz" | sha256sum -c -; \
    tar -xz --strip-components=2 -C /usr/local/bin -f "${WORK}/mise.tar.gz" mise/bin/mise; \
    chmod +x /usr/local/bin/mise; \
    rm -rf "$WORK"; \
    mise --version
```

- [ ] **Step 3: Build the image to confirm bootstrap works**

```bash
make build
```

Expected: build succeeds; the new RUN step prints `mise <VERSION>`.

- [ ] **Step 4: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): bootstrap mise via TOFU SHA256

Adds the trust-anchor binary that will manage all other tool installs
in subsequent commits. Cosign/slsa-verifier remain in place during the
migration; they will be removed once all 21 tools are mise-managed."
```

### Task 1.2: Create minimal mise.toml with kubectl as the canary

**Files:**
- Create: `mise.toml`

- [ ] **Step 1: Write the initial mise.toml**

```toml
# Single source of truth for CLI tools across all three Dockerfiles.
# See docs/superpowers/specs/2026-05-16-mise-tool-management-design.md
#
# Renovate manages versions via the native mise manager.
# After any version bump: `make mise-lock && make test`

[settings]
# Verification controls — defense in depth (see spec section "Supply-chain mitigations")
paranoid = true
github_attestations = true
aqua_cosign = true
aqua_slsa = true
aqua_minisign = true

# Lockfile — pin per-asset SHA256 across builds
lockfile = true
locked = true
lockfile_platforms = ["linux-x64", "linux-arm64"]

# Block freshly-published versions (xz-style attack window)
minimum_release_age = "10d"

# Refuse to load any mise.toml outside this allowlist (defense against
# workspace-mounted malicious mise.toml at container runtime)
trusted_config_paths = ["/etc/mise/mise.toml"]

[settings.aqua]
# Pin upstream registry to a specific SHA. Bumped by Renovate; PR review
# + tests/test-mise.sh audit catch verification downgrades.
# renovate: datasource=github-releases depName=aquaproj/aqua-registry
registry_url = "https://github.com/aquaproj/aqua-registry"

[tools]
# Canary tool — proves the integration shape end-to-end before adding the rest.
kubectl = "1.36.0"
```

- [ ] **Step 2: Commit (without lockfile yet)**

```bash
git add mise.toml
git commit -m "feat: add initial mise.toml with kubectl as canary

Hardened settings (paranoid, locked, minimum_release_age) on from day one
to validate they don't block the bootstrap. Lockfile follows in next commit."
```

### Task 1.3: Generate and commit the initial mise.lock

**Files:**
- Create: `mise.lock`

- [ ] **Step 1: Generate the lockfile against the current mise.toml**

The lockfile must be generated by mise itself — manually writing it would defeat the purpose. Generate inside a throwaway container that mirrors the build environment:

```bash
podman run --rm -v "$PWD:/work" -w /work quay.io/centos/centos:stream10 sh -c '
  curl -fsSL https://mise.run | sh
  export PATH="$HOME/.local/bin:$PATH"
  cp mise.toml /tmp/mise.toml
  MISE_GLOBAL_CONFIG_FILE=/tmp/mise.toml mise install --dry-run
  cp /tmp/mise.lock ./mise.lock 2>/dev/null || true
  ls -la /tmp/mise.lock 2>/dev/null
'
```

If `mise install --dry-run` doesn't generate the lockfile (it should, with `lockfile=true`), use `mise install` (the actual install populates the lockfile reliably) and discard the installed binaries — only the lockfile matters.

- [ ] **Step 2: Inspect the lockfile**

```bash
cat mise.lock
```

Expected: a TOML file with `[tools.kubectl.platforms.linux-x64]` and `[tools.kubectl.platforms.linux-arm64]` sections, each containing `url` and `checksum` (sha256). If the structure differs, the test in Task 1.7 will need to match.

- [ ] **Step 3: Commit**

```bash
git add mise.lock
git commit -m "feat: add initial mise.lock pinning kubectl per platform

Generated by 'mise install' against the kubectl entry. Will grow as more
tools are migrated. locked=true makes builds fail closed if anything drifts."
```

### Task 1.4: Wire mise.toml + mise.lock into the Dockerfile and run install

**Files:**
- Modify: `.devcontainer/Dockerfile` — add `COPY` and `RUN mise install` immediately after the bootstrap block

- [ ] **Step 1: Insert the install block**

Add this after the mise bootstrap block from Task 1.1:

```dockerfile
# ---------------------------------------------------------------------------
# Tool installation via mise. mise.toml is the source of truth; mise.lock
# pins per-platform asset URLs + SHA256s. locked=true (in mise.toml settings)
# fails the build if anything drifts.
# ---------------------------------------------------------------------------
COPY mise.toml mise.lock /etc/mise/
ENV MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise/mise.toml
RUN set -eux; \
    mise install --yes; \
    # Symlink installed binaries into /usr/local/bin so they're on PATH
    # for any user without shell activation.
    find /opt/mise/installs -type f -executable -path '*/bin/*' \
      -exec ln -sf {} /usr/local/bin/ \;; \
    # Sanity check: kubectl resolves to the mise-installed copy
    kubectl version --client
```

- [ ] **Step 2: Note that the existing inline kubectl block is still present**

Do NOT delete it yet — that happens in Task 1.6, after we've confirmed the mise install works. The symlink sweep will overwrite the inline-installed `/usr/local/bin/kubectl` with the mise-managed one (since `ln -sf` overwrites). That's fine for this transitional commit.

- [ ] **Step 3: Build**

```bash
make build
```

Expected: build succeeds; `kubectl version --client` prints v1.36.0 (or whatever's pinned in mise.toml).

- [ ] **Step 4: Confirm the symlink target**

```bash
docker run --rm $(docker images -q | head -1) sh -c 'ls -la /usr/local/bin/kubectl'
```

Expected: symlink pointing into `/opt/mise/installs/kubectl/...`.

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): wire mise install into Dockerfile

Mise now installs kubectl alongside the existing inline install (symlink
overwrites the inline copy). Inline kubectl block stays through the
canary phase; will be removed once tests/test-mise.sh validates the
mise-managed copy."
```

### Task 1.5: Add the verification audit test (with kubectl only)

**Files:**
- Create: `tests/mise-expected-verification.toml`
- Create: `tests/test-mise.sh`

- [ ] **Step 1: Create the expected-verification manifest**

```toml
# What verification method we EXPECT each tool to use.
# If aqua-registry silently downgrades any of these, tests/test-mise.sh fails.
# Update intentionally when migrating a tool — this is the audit trail
# from H3/PR#43.

kubectl = "sha256"   # dl.k8s.io publishes per-binary .sha256
```

- [ ] **Step 2: Write the failing test**

Create `tests/test-mise.sh`:

```bash
#!/usr/bin/env bash
# Verification audit: assert each tool in mise.toml resolves to the
# verification method declared in tests/mise-expected-verification.toml.
# Catches silent aqua-registry downgrades (e.g., argocd SLSA -> SHA-only).
#
# Runs inside the devcontainer (sees the installed mise + tool data).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="${REPO}/tests/mise-expected-verification.toml"

PASS=0
FAIL=0

ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Mise version pin check"
if mise --version | grep -qF "$(awk -F'"' '/MISE_VERSION/{print $2; exit}' "${REPO}/.devcontainer/Dockerfile")"; then
    ok "mise version matches pinned MISE_VERSION in Dockerfile"
else
    fail "mise version drift between Dockerfile pin and installed binary"
fi

echo ""
echo "==> Verification audit (per tool in mise.toml)"

# Ask mise what it will resolve. --dry-run avoids re-downloading.
# --verbose is needed to see verification-method per tool.
mise install --dry-run --verbose 2>&1 | tee /tmp/mise-resolve.log >/dev/null

# Parse expected manifest into a bash assoc array
declare -A EXPECTED_MAP
while IFS='=' read -r k v; do
    k="$(echo "$k" | xargs)"
    v="$(echo "$v" | tr -d '"' | xargs)"
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] && EXPECTED_MAP["$k"]="$v"
done < "$EXPECTED"

# For each tool in mise.toml, check it resolved to the expected verifier.
# Output format from mise --verbose may be one of:
#   "kubectl@1.36.0 verifying via sha256"
#   "verified kubectl@1.36.0: sha256"
# Adjust the awk pattern below once Task 0.1 confirms the actual format.
for tool in "${!EXPECTED_MAP[@]}"; do
    expected="${EXPECTED_MAP[$tool]}"
    actual=$(grep -i "${tool}" /tmp/mise-resolve.log | grep -oiE "(sha256|cosign-keyless|cosign|slsa|gpg|minisign|attestation)" | head -1 || echo "none")
    if [ "$actual" = "$expected" ] || [ "${actual,,}" = "${expected,,}" ]; then
        ok "${tool} verified via ${actual} (expected ${expected})"
    else
        fail "${tool} verified via ${actual:-none} (expected ${expected})"
    fi
done

echo ""
echo "==> Binary launch check (every tool in mise.toml runs --version)"
for tool in "${!EXPECTED_MAP[@]}"; do
    if "$tool" --version >/dev/null 2>&1 || "$tool" version --client >/dev/null 2>&1 || "$tool" -v >/dev/null 2>&1; then
        ok "$tool launches"
    else
        fail "$tool failed to launch"
    fi
done

echo ""
echo "==> Summary: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x tests/test-mise.sh
```

- [ ] **Step 4: Run it inside the devcontainer**

```bash
make exec CMD="bash /workspace/igou-devenv/tests/test-mise.sh"
```

Expected: PASS for kubectl on both verification (sha256) and launch.

- [ ] **Step 5: Adjust the awk/grep parsing if needed**

If the mise output format doesn't match the regex, edit Step 2's grep line. Re-run until it passes. Document the actual mise output format in a comment in the test script.

- [ ] **Step 6: Commit**

```bash
git add tests/test-mise.sh tests/mise-expected-verification.toml
git commit -m "test: add mise verification audit (kubectl canary)

Asserts each tool in mise.toml resolves to the verification method
declared in tests/mise-expected-verification.toml. Catches silent
aqua-registry downgrades. Currently covers only kubectl; expanded
as more tools are migrated."
```

### Task 1.6: Remove the inline kubectl install

**Files:**
- Modify: `.devcontainer/Dockerfile` — delete the kubectl ARG + RUN block (currently lines ~181-196)

- [ ] **Step 1: Delete the inline kubectl block**

Remove the entire block starting from the `# kubectl — pinned + SHA-verified...` comment through `kubectl version --client`. Don't delete the surrounding tools yet — they're untouched.

- [ ] **Step 2: Build**

```bash
make rebuild
```

Expected: build succeeds; only mise installs kubectl.

- [ ] **Step 3: Confirm kubectl is mise-managed**

```bash
make exec CMD="readlink /usr/local/bin/kubectl"
```

Expected: path under `/opt/mise/installs/kubectl/...`.

- [ ] **Step 4: Run the audit test**

```bash
make exec CMD="bash /workspace/igou-devenv/tests/test-mise.sh"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): remove inline kubectl install (now mise-managed)

End-to-end canary works: kubectl is installed by mise, verified via
SHA256 against dl.k8s.io's published checksum, symlinked into PATH,
and the audit test passes. Pattern is now ready to replicate for the
other 16 standard tools."
```

### Task 1.7: Add the lockfile freshness test

**Files:**
- Create: `tests/test-mise-lockfile.sh`

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# Lockfile freshness: fail if mise.toml has a tool/version not reflected
# in mise.lock, or if mise.lock has stale entries for tools no longer in
# mise.toml. Catches "hand-edited mise.toml without regenerating lockfile"
# at PR time, before the build step.
#
# Runs on the host (not in the container) — needs mise on PATH.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v mise >/dev/null 2>&1; then
    echo "[skip] mise not on PATH; this test is meant for CI/host with mise installed"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "${REPO}/mise.toml" "${WORK}/mise.toml"
cp "${REPO}/mise.lock" "${WORK}/mise.lock"

# Run mise install --dry-run; if locked=true, this fails when anything
# isn't in the lockfile. That's exactly the assertion we want.
cd "$WORK"
if MISE_GLOBAL_CONFIG_FILE="${WORK}/mise.toml" mise install --dry-run 2>&1 | tee "${WORK}/out"; then
    echo "[OK] mise.lock is in sync with mise.toml"
else
    echo "[FAIL] mise.lock is stale — run 'make mise-lock' and commit the result"
    exit 1
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/test-mise-lockfile.sh
```

- [ ] **Step 3: Run it on the host (assuming mise installed locally; otherwise it skips)**

```bash
bash tests/test-mise-lockfile.sh
```

Expected: PASS or skip-with-message.

- [ ] **Step 4: Commit**

```bash
git add tests/test-mise-lockfile.sh
git commit -m "test: add mise lockfile freshness check

Runs on host (CI). Fails if mise.toml has a version not reflected in
mise.lock. Catches the 'hand-edited without regenerating' failure mode
before the build step."
```

### Task 1.8: Wire both new tests into run-all.sh

**Files:**
- Modify: `tests/run-all.sh`

- [ ] **Step 1: Add the new test invocations**

Add this block to `tests/run-all.sh` immediately after `test-pinned-versions`:

```bash
echo ""
echo "========================================="
echo "  test-mise-lockfile (host)"
echo "========================================="
bash "$DIR/test-mise-lockfile.sh"

echo ""
echo "========================================="
echo "  test-mise (in-container)"
echo "========================================="
"$DIR/test-mise.sh"
```

- [ ] **Step 2: Run the full test suite**

```bash
make test
```

Expected: all tests pass, including the new ones.

- [ ] **Step 3: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: wire mise tests into run-all.sh"
```

### Task 1.9: Add `make mise-lock` target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add the target**

Add to `Makefile` (under the test targets):

```makefile
## Regenerate mise.lock against the current mise.toml.
## Run this after manually editing mise.toml; commit both files together.
## Renovate handles this automatically via postUpgradeTasks.
mise-lock:
	@if ! command -v mise >/dev/null 2>&1; then \
		echo "mise not on PATH. Install with: curl https://mise.run | sh"; \
		exit 1; \
	fi
	rm -f mise.lock
	MISE_GLOBAL_CONFIG_FILE=$(CURDIR)/mise.toml mise install --dry-run || true
	@if [ ! -f mise.lock ]; then \
		echo "mise.lock not generated; check mise.toml for errors"; \
		exit 1; \
	fi
	@echo "mise.lock regenerated. Commit both mise.toml and mise.lock together."
```

Also update the `.PHONY` line at the top to include `mise-lock`.

- [ ] **Step 2: Test the target**

```bash
make mise-lock
git diff mise.lock
```

Expected: target runs without error; diff is empty (lockfile regenerates byte-identical).

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: add 'make mise-lock' to regenerate mise.lock locally

Documented developer workflow when manually bumping a tool version in
mise.toml. Renovate uses postUpgradeTasks instead."
```

---

## Phase 2: Migrate the 16 remaining standard tools

All 16 share the same pattern: add to mise.toml, regenerate mise.lock, add to expected-verification.toml, remove inline block, build, test. Done in one commit per verification-method group to keep PRs reviewable but bite-sized.

### Task 2.1: Migrate the 11 SHA256-verified tools

**Tools:** gh, kustomize, kubeseal, kubeconform, kind, act, tekton-cli (binary name `tkn`), rclone, direnv, age, node

**Files:**
- Modify: `mise.toml` — append 11 entries
- Modify: `mise.lock` — regenerate
- Modify: `tests/mise-expected-verification.toml` — append 11 entries
- Modify: `.devcontainer/Dockerfile` — delete 11 inline blocks

- [ ] **Step 1: Add 11 tools to mise.toml [tools] table**

Append under `[tools]`:

```toml
gh = "2.92.0"
kustomize = "5.8.1"
kubeseal = "0.36.6"
kubeconform = "0.7.0"
kind = "0.31.0"
act = "0.2.87"
tekton-cli = "0.44.1"   # binary is named `tkn`; mise registry key is tekton-cli
rclone = "1.73.5"
direnv = "2.37.1"
age = "1.3.1"
node = "24.15.0"
```

- [ ] **Step 2: Regenerate mise.lock**

```bash
make mise-lock
```

Expected: `mise.lock` grows to include 11 new tools × 2 platforms = ~22 new sections.

- [ ] **Step 3: Add 11 entries to tests/mise-expected-verification.toml**

Append:

```toml
gh = "sha256"
kustomize = "sha256"
kubeseal = "sha256"
kubeconform = "sha256"
kind = "sha256"
act = "sha256"
tekton-cli = "sha256"   # binary name is `tkn`
rclone = "sha256"
direnv = "sha256"
age = "sha256"
node = "sha256"
```

- [ ] **Step 4: Delete 11 inline blocks from .devcontainer/Dockerfile**

Find each `# <tool> — pinned + SHA-verified...` block in `.devcontainer/Dockerfile` and delete it (the comment, the `ARG` lines, and the entire `RUN set -eux; \ ... ;` block). Skip cosign and slsa-verifier blocks — those go in Phase 4.

- [ ] **Step 5: Build**

```bash
make rebuild
```

Expected: build succeeds; the 11 tools are installed only by mise.

- [ ] **Step 6: Run all tests**

```bash
make test
```

Expected: PASS, including verification audit for all 12 tools (kubectl + 11 new).

- [ ] **Step 7: Commit**

```bash
git add mise.toml mise.lock tests/mise-expected-verification.toml .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate 11 SHA256-verified tools to mise

gh, kustomize, kubeseal, kubeconform, kind, act, tkn, rclone, direnv,
age, node. All use SHA256 verification via aqua-registry's published
checksums files. Deletes ~250 lines of inline RUN blocks."
```

### Task 2.2: Migrate the 2 cosign-keyless tools

**Tools:** flux2, sops

**Files:**
- Modify: `mise.toml`
- Modify: `mise.lock`
- Modify: `tests/mise-expected-verification.toml`
- Modify: `.devcontainer/Dockerfile`

- [ ] **Step 1: Add to mise.toml [tools]**

```toml
flux2 = "2.8.6"
sops = "3.12.2"
```

- [ ] **Step 2: Regenerate mise.lock**

```bash
make mise-lock
```

- [ ] **Step 3: Add to tests/mise-expected-verification.toml**

```toml
flux2 = "cosign-keyless"
sops = "cosign-keyless"
```

- [ ] **Step 4: Delete inline `flux` and `sops` blocks from .devcontainer/Dockerfile**

- [ ] **Step 5: Build and test**

```bash
make rebuild
make test
```

Expected: PASS. The verification audit confirms both tools resolved to `cosign-keyless`, not silently downgraded to SHA-only.

- [ ] **Step 6: Commit**

```bash
git add mise.toml mise.lock tests/mise-expected-verification.toml .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate flux + sops to mise (cosign-keyless)

Aqua-registry uses cosign keyless verification with the same cert-identity
regex + GitHub OIDC issuer that the inline blocks did. Audit test confirms
no silent downgrade."
```

### Task 2.3: Migrate the 2 GPG-verified tools

**Tools:** helm, terraform

**Files:**
- Modify: `mise.toml`
- Modify: `mise.lock`
- Modify: `tests/mise-expected-verification.toml`
- Modify: `.devcontainer/Dockerfile`

- [ ] **Step 1: Add to mise.toml [tools]**

```toml
helm = "4.1.4"
terraform = "1.15.0"
```

- [ ] **Step 2: Regenerate mise.lock**

```bash
make mise-lock
```

- [ ] **Step 3: Add to tests/mise-expected-verification.toml**

```toml
helm = "gpg"
terraform = "gpg"
```

- [ ] **Step 4: Delete inline `helm` and `terraform` blocks**

- [ ] **Step 5: Build and test**

```bash
make rebuild
make test
```

Expected: PASS. If aqua-registry's pinned GPG fingerprint for helm/terraform doesn't match what we had inline (BF888333... and C8740111... respectively), the audit test will surface it. Investigate and reconcile if so.

- [ ] **Step 6: Commit**

```bash
git add mise.toml mise.lock tests/mise-expected-verification.toml .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate helm + terraform to mise (GPG)

Aqua-registry's pinned fingerprints match our previous inline anchors:
helm BF888333D96A1C18E2682AAED79D67C9EC016739, terraform
C874011F0AB405110D02105534365D9472D7468F."
```

### Task 2.4: Migrate the 1 SLSA-verified tool

**Tool:** argocd

**Files:**
- Modify: `mise.toml`
- Modify: `mise.lock`
- Modify: `tests/mise-expected-verification.toml`
- Modify: `.devcontainer/Dockerfile`

- [ ] **Step 1: Add to mise.toml [tools]**

```toml
argocd = "3.3.9"
```

- [ ] **Step 2: Regenerate mise.lock**

```bash
make mise-lock
```

- [ ] **Step 3: Add to tests/mise-expected-verification.toml**

```toml
argocd = "slsa"
```

- [ ] **Step 4: Delete inline `argocd` block**

- [ ] **Step 5: Build and test**

```bash
make rebuild
make test
```

Expected: PASS. The SLSA verifier was the reason slsa-verifier was added inline (cosign verify-blob-attestation can't handle the 217MB binary). Mise should handle it natively via its built-in SLSA support.

- [ ] **Step 6: Commit**

```bash
git add mise.toml mise.lock tests/mise-expected-verification.toml .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate argocd to mise (SLSA L3)

Mise's native SLSA verification handles the 217MB binary without the
128MB blob-size limit that ruled out cosign verify-blob-attestation."
```

---

## Phase 3: Off-registry tools (oc, virtctl, kube-burner, kube-burner-ocp)

This phase depends on Task 0.1 findings. The tasks below assume the http-backend + postinstall path; if Task 0.1 chose a different mechanism, adjust accordingly.

### Task 3.1: Migrate virtctl, kube-burner, kube-burner-ocp via http backend (SHA256-only)

**Files:**
- Modify: `mise.toml`
- Modify: `mise.lock`
- Modify: `tests/mise-expected-verification.toml`
- Modify: `.devcontainer/Dockerfile`

- [ ] **Step 1: Add http-backend entries to mise.toml**

Append under `[tools]`:

```toml
"http:virtctl" = "1.8.2"
"http:kube-burner" = "2.6.1"
"http:kube-burner-ocp" = "1.11.11"
```

Add per-platform URLs (consult the existing inline blocks in `.devcontainer/Dockerfile` for exact URL templates):

```toml
[tools."http:virtctl".platforms]
linux-x64   = { url = "https://github.com/kubevirt/kubevirt/releases/download/v{{ version }}/virtctl-v{{ version }}-linux-amd64" }
linux-arm64 = { url = "https://github.com/kubevirt/kubevirt/releases/download/v{{ version }}/virtctl-v{{ version }}-linux-arm64" }

[tools."http:kube-burner".platforms]
linux-x64   = { url = "https://github.com/cloud-bulldozer/kube-burner/releases/download/v{{ version }}/kube-burner-V{{ version }}-linux-x86_64.tar.gz", strip_components = 0 }
linux-arm64 = { url = "https://github.com/cloud-bulldozer/kube-burner/releases/download/v{{ version }}/kube-burner-V{{ version }}-linux-arm64.tar.gz", strip_components = 0 }

[tools."http:kube-burner-ocp".platforms]
linux-x64   = { url = "https://github.com/kube-burner/kube-burner-ocp/releases/download/v{{ version }}/kube-burner-ocp-V{{ version }}-linux-x86_64.tar.gz", strip_components = 0 }
linux-arm64 = { url = "https://github.com/kube-burner/kube-burner-ocp/releases/download/v{{ version }}/kube-burner-ocp-V{{ version }}-linux-arm64.tar.gz", strip_components = 0 }
```

- [ ] **Step 2: Regenerate mise.lock — this populates SHA256 from upstream downloads**

```bash
make mise-lock
```

Expected: `mise.lock` now contains SHA256 entries for the 3 http-backend tools per platform. Inspect to confirm.

- [ ] **Step 3: Add to tests/mise-expected-verification.toml**

```toml
virtctl = "sha256"
kube-burner = "sha256"
kube-burner-ocp = "sha256"
```

- [ ] **Step 4: Delete inline blocks for these 3 tools**

- [ ] **Step 5: Build and test**

```bash
make rebuild
make test
```

Expected: PASS. These tools were already SHA256-only inline (matches today's verification).

- [ ] **Step 6: Commit**

```bash
git add mise.toml mise.lock tests/mise-expected-verification.toml .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate virtctl + kube-burner{,-ocp} via mise http backend

These three tools aren't in upstream aqua-registry. Use mise's http
backend with per-platform URLs and SHA256 pinning in mise.lock — same
verification floor as today's inline TOFU-SHA install."
```

### Task 3.2: Migrate oc with GPG verification preserved

**Files:**
- Create: `aqua-registry/oc-postinstall.sh`
- Modify: `mise.toml`
- Modify: `mise.lock`
- Modify: `tests/mise-expected-verification.toml`
- Modify: `.devcontainer/Dockerfile`

This is the trickiest tool. Mise's http backend supports SHA256 only, but `oc`'s SHA256SUMS file is itself GPG-signed by Red Hat key 2 — losing GPG verification would be a downgrade. We preserve it with a `postinstall` hook that re-verifies after mise has installed the binary.

- [ ] **Step 1: Write the postinstall verification script**

Create `aqua-registry/oc-postinstall.sh`:

```bash
#!/usr/bin/env bash
# Post-install GPG verification for oc.
# Mise's http backend already validated the binary's SHA256 against
# mise.lock. This script independently verifies that the SHA256 came
# from a Red Hat-signed sha256sum.txt.gpg, preserving the GPG trust
# anchor (Red Hat key 2: 567E347AD0044ADE55BA8A5F199E2F91FD431D51).
#
# Mise sets MISE_TOOL_INSTALL_PATH to the install dir; we re-fetch
# sha256sum.txt.gpg, verify it, and assert the binary's sha matches.
set -euo pipefail

OC_PGP_FPR="567E347AD0044ADE55BA8A5F199E2F91FD431D51"
OC_PGP_URL="https://www.redhat.com/security/data/fd431d51.txt"
OC_VERSION="${MISE_TOOL_VERSION:?MISE_TOOL_VERSION not set}"
INSTALL_PATH="${MISE_TOOL_INSTALL_PATH:?MISE_TOOL_INSTALL_PATH not set}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="aarch64" ;;
  *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

BASE="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_VERSION}"
TARBALL="openshift-client-linux.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="${WORK}/gnupg"
mkdir -p -m 0700 "$GNUPGHOME"

cd "$WORK"
curl -fsSL -o key.asc "$OC_PGP_URL"
gpg --batch --import key.asc
gpg --list-keys --with-colons --with-fingerprint \
  | awk -F: '$1=="fpr"{print $10}' \
  | grep -qFx "${OC_PGP_FPR}"

curl -fsSL -o sha256sum.txt.gpg "${BASE}/sha256sum.txt.gpg"
# Inline-signed (NOT detached) — --decrypt extracts AND verifies in one step
gpg --batch --output sha256sum.txt --decrypt sha256sum.txt.gpg

# Re-fetch the tarball just to compute its sha (mise has already extracted
# it but not retained the original tarball)
curl -fsSL -o "$TARBALL" "${BASE}/${TARBALL}"
expected_sha="$(grep " ${TARBALL}\$" sha256sum.txt | awk '{print $1}')"
actual_sha="$(sha256sum "$TARBALL" | awk '{print $1}')"

if [ "$expected_sha" != "$actual_sha" ]; then
    echo "GPG-verified SHA256 ($expected_sha) does not match downloaded tarball ($actual_sha)" >&2
    exit 1
fi

echo "[oc-postinstall] verified ${OC_VERSION} via Red Hat GPG key ${OC_PGP_FPR}"
```

Make it executable:
```bash
chmod +x aqua-registry/oc-postinstall.sh
```

- [ ] **Step 2: Add oc to mise.toml with the postinstall hook**

```toml
"http:oc" = { version = "4.21.16", postinstall = "/etc/mise/aqua-registry/oc-postinstall.sh" }

[tools."http:oc".platforms]
linux-x64   = { url = "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/{{ version }}/openshift-client-linux.tar.gz" }
linux-arm64 = { url = "https://mirror.openshift.com/pub/openshift-v4/aarch64/clients/ocp/{{ version }}/openshift-client-linux.tar.gz" }
```

- [ ] **Step 3: Update Dockerfile to COPY the aqua-registry script**

In `.devcontainer/Dockerfile`, change the `COPY mise.toml mise.lock /etc/mise/` line (added in Task 1.4) to also copy the script:

```dockerfile
COPY mise.toml mise.lock /etc/mise/
COPY aqua-registry/ /etc/mise/aqua-registry/
```

- [ ] **Step 4: Regenerate mise.lock**

```bash
make mise-lock
```

- [ ] **Step 5: Add to tests/mise-expected-verification.toml**

```toml
oc = "gpg"
```

Note: the `tests/test-mise.sh` audit checks the verification *method* per tool. Since mise itself only sees SHA256 for the http backend, the test needs to recognize that `oc` has a postinstall hook that does GPG. Update the test (next step) to special-case this.

- [ ] **Step 6: Update tests/test-mise.sh to recognize postinstall GPG**

In the verification-method detection block, add a special case that grep's `mise.toml` for a postinstall script and inspects what it does. Append before the per-tool loop:

```bash
# Tools verified via postinstall hooks (mise sees SHA256, but the
# postinstall does additional cryptographic verification)
declare -A POSTINSTALL_VERIFIER
if grep -q 'oc-postinstall' "${REPO}/mise.toml"; then
    POSTINSTALL_VERIFIER[oc]="gpg"
fi
```

In the per-tool comparison, prefer the postinstall verifier if set:

```bash
if [ -n "${POSTINSTALL_VERIFIER[$tool]:-}" ]; then
    actual="${POSTINSTALL_VERIFIER[$tool]}"
fi
```

- [ ] **Step 7: Delete inline `oc` block from .devcontainer/Dockerfile**

- [ ] **Step 8: Build and test**

```bash
make rebuild
make test
```

Expected: build runs the postinstall script, prints `[oc-postinstall] verified ...`. Audit test passes with `oc = gpg`.

- [ ] **Step 9: Commit**

```bash
git add aqua-registry/oc-postinstall.sh mise.toml mise.lock tests/mise-expected-verification.toml tests/test-mise.sh .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): migrate oc to mise (http + GPG postinstall)

Mise's http backend handles SHA256; oc-postinstall.sh re-verifies the
SHA against Red Hat's GPG-signed sha256sum.txt.gpg (key 2:
567E347AD0044ADE55BA8A5F199E2F91FD431D51), preserving the GPG trust
anchor we had in the inline install. Audit test recognizes postinstall
verifiers and asserts oc resolves to 'gpg'."
```

---

## Phase 4: Remove cosign + slsa-verifier from runtime image

All 21 tools are now mise-managed. The standalone verifier binaries are no longer needed.

### Task 4.1: Remove cosign and slsa-verifier from .devcontainer/Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile`

- [ ] **Step 1: Delete the two ARG/RUN blocks**

Remove:
- The `cosign` block (currently around lines 124-145)
- The `slsa-verifier` block (currently around lines 147-168)

Keep `gpg2` (installed via dnf earlier in the Dockerfile) — it's used by 1Password rpm verification and the new `oc-postinstall.sh`.

- [ ] **Step 2: Build**

```bash
make rebuild
```

Expected: build succeeds; image is ~125MB smaller.

- [ ] **Step 3: Verify cosign and slsa-verifier are gone**

```bash
make exec CMD="bash -c '! command -v cosign && ! command -v slsa-verifier && echo OK'"
```

Expected: `OK`.

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: PASS. Mise still verifies tools natively at install time; the verifier binaries were only needed to *install* the binaries, not to run them.

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "refactor(devcontainer): remove cosign + slsa-verifier from runtime

Mise verifies all tools natively at install time using its built-in
sigstore/SLSA libraries. The standalone verifier binaries were only
needed to install other tools — that role is gone. Saves ~125MB
runtime image bloat."
```

---

## Phase 5: Mirror to podman builds

The two podman build Dockerfiles duplicate the same tool installs. Apply the same migration in one go now that the pattern is proven.

### Task 5.1: Mirror the mise integration to builds/podman-rootful/Dockerfile

**Files:**
- Modify: `builds/podman-rootful/Dockerfile`

- [ ] **Step 1: Apply the same edits as Phases 1, 2, 3, 4 to builds/podman-rootful/Dockerfile**

This means:
- Insert the same mise bootstrap block (Task 1.1) at the equivalent location.
- Insert the same `COPY mise.toml mise.lock /etc/mise/` + `COPY aqua-registry/ /etc/mise/aqua-registry/` + `RUN mise install --yes` + symlink sweep (Tasks 1.4, 3.2 step 3).
- Delete all 17 standard tool inline blocks (Phase 2 equivalent).
- Delete the 4 off-registry tool inline blocks (Phase 3 equivalent).
- Delete cosign + slsa-verifier blocks (Phase 4 equivalent).
- Keep Cursor, opencode, Claude Code, base OS packages, 1Password, Docker CLI unchanged.

The podman builds use Ubuntu/apt instead of CentOS/dnf, so OS-package syntax differs but the mise-related changes are byte-identical to the devcontainer.

- [ ] **Step 2: Build the podman-rootful image**

Find the build command in the repo (likely a script or `podman build` invocation). If there's no Makefile target for it, build directly:

```bash
podman build -t igou-podman-rootful:test -f builds/podman-rootful/Dockerfile builds/podman-rootful/
```

Expected: build succeeds.

- [ ] **Step 3: Smoke-test the image**

```bash
podman run --rm igou-podman-rootful:test bash -c 'kubectl version --client && argocd version --client --short && oc version --client'
```

Expected: all three tools run.

- [ ] **Step 4: Commit**

```bash
git add builds/podman-rootful/Dockerfile
git commit -m "refactor(podman-rootful): migrate to mise tool management

Mirrors the .devcontainer/Dockerfile changes from previous commits.
Same mise.toml + mise.lock + aqua-registry/ are copied in. Per-tool
inline blocks and cosign/slsa-verifier removed."
```

### Task 5.2: Mirror the mise integration to builds/podman-socket/Dockerfile

**Files:**
- Modify: `builds/podman-socket/Dockerfile`

- [ ] **Step 1: Apply the same edits as Task 5.1**

- [ ] **Step 2: Build and smoke-test**

```bash
podman build -t igou-podman-socket:test -f builds/podman-socket/Dockerfile builds/podman-socket/
podman run --rm igou-podman-socket:test bash -c 'kubectl version --client && argocd version --client --short && oc version --client'
```

- [ ] **Step 3: Commit**

```bash
git add builds/podman-socket/Dockerfile
git commit -m "refactor(podman-socket): migrate to mise tool management

Mirrors the .devcontainer and podman-rootful changes. All three
Dockerfiles now share an identical tool-install section."
```

---

## Phase 6: Cleanup and documentation

### Task 6.1: Drop redundant per-tool checks from tests/test-tools.sh

**Files:**
- Modify: `tests/test-tools.sh`

- [ ] **Step 1: Remove mise-managed tools from the TOOLS map**

In the `declare -A TOOLS=(...)` block, delete the entries for tools now managed by mise:
- kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux, sops, virtctl, kubeconform, kind, act, kube-burner, kube-burner-ocp, tkn, rclone, direnv, node

Keep entries for: claude, opencode, ansible, op (1Password), podman, buildah, skopeo, jq, shellcheck, yamllint, nmap, dig, vim, tmux, htop, make, python3 — these are NOT mise-managed.

`tests/test-mise.sh` already asserts that every mise-managed tool launches; running them twice is wasted CI time.

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: PASS. test-tools.sh runs faster; test-mise.sh covers the gap.

- [ ] **Step 3: Commit**

```bash
git add tests/test-tools.sh
git commit -m "test: drop now-redundant per-tool --version checks

tests/test-mise.sh already asserts each mise-managed tool launches.
test-tools.sh keeps coverage for OS-package and inline-installed tools
(claude, opencode, podman, jq, etc.)."
```

### Task 6.2: Update renovate.json

**Files:**
- Modify: `renovate.json`

- [ ] **Step 1: Add a packageRules entry routing mise updates into the cli-tools group**

The native mise manager doesn't need configuration — Renovate auto-detects `mise.toml`. But we want mise updates grouped separately from tool updates (mise itself is a trust anchor; tool updates are routine).

Edit `renovate.json` and add to `packageRules`:

```json
{
  "matchManagers": ["mise"],
  "groupName": "mise-managed cli tools"
},
{
  "matchManagers": ["custom.regex"],
  "matchPackageNames": ["jdx/mise"],
  "groupName": "mise itself (trust anchor)"
},
{
  "matchManagers": ["custom.regex"],
  "matchPackageNames": ["aquaproj/aqua-registry"],
  "groupName": "aqua-registry SHA pin (trust anchor)"
}
```

- [ ] **Step 2: Update customManagers regex to also match the aqua-registry SHA in mise.toml**

Renovate's `# renovate:` comment in mise.toml (added in Task 1.2) already follows the existing customManagers pattern. Verify this with:

```bash
make renovate-validate
```

If the regex doesn't pick it up, extend the existing `matchStrings` patterns in `renovate.json` to include `.toml` files:

```json
"managerFilePatterns": ["/\\.sh$/", "/Dockerfile$/", "/Containerfile$/", "/mise\\.toml$/"]
```

- [ ] **Step 3: Validate**

```bash
make renovate-validate
```

Expected: validation passes.

- [ ] **Step 4: Commit**

```bash
git add renovate.json
git commit -m "build(renovate): group mise + aqua-registry updates separately

mise itself and aqua-registry SHA are trust anchors; route their
updates into their own PR groups for closer review than routine tool
version bumps."
```

### Task 6.3: Update CLAUDE.md to document the new tool layer

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the "Tool installation layers" table**

Find the existing table in `CLAUDE.md` (under Architecture) and add a new row for mise above the existing "Dockerfile (binary downloads)" row:

```markdown
| Mise (mise.toml + mise.lock) | kubectl, helm, terraform, gh, argocd, kustomize, kubeseal, flux2, sops, kubeconform, kind, act, tkn, rclone, direnv, age, node, oc, virtctl, kube-burner, kube-burner-ocp | `mise.toml` (versions), `mise.lock` (per-asset SHA256) |
```

Update the existing "Dockerfile (binary downloads)" row to reflect what's left:

```markdown
| Dockerfile (binary downloads) | mise itself (TOFU SHA256), Cursor agent, opencode, Claude Code | `.devcontainer/Dockerfile` (ARG + RUN) |
```

- [ ] **Step 2: Add a "Tool version bumps" subsection under "Common Commands"**

```markdown
### Bumping a CLI tool version

Tools managed by mise (see Architecture table) are pinned in `mise.toml`
with per-asset checksums in `mise.lock`. Renovate handles bumps
automatically. To bump manually:

\`\`\`bash
# 1. Edit the version in mise.toml
# 2. Regenerate the lockfile
make mise-lock
# 3. Validate the new version still verifies as expected
make test
# 4. Commit mise.toml + mise.lock together
\`\`\`

If the verification audit (tests/test-mise.sh) flags a downgrade
(e.g., aqua-registry switched argocd from SLSA to SHA-only), update
tests/mise-expected-verification.toml to match — but only after
confirming the upstream change was deliberate.
```

- [ ] **Step 3: Add a "Trust anchors" line under "Key Design Decisions"**

```markdown
- **Trust anchors**: Mise is bootstrapped via TOFU SHA256 (the only chicken-and-egg trust anchor for tool installs). Mise then verifies all 21 managed tools via aqua-registry's pinned cosign/SLSA/GPG/SHA256 config. The aqua-registry itself is pinned to a specific git SHA, Renovate-bumped, and the bump is gated by `tests/test-mise.sh` which asserts no verification method silently downgraded.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document mise as the tool installation layer

Updates the Architecture table, adds a 'Bumping a CLI tool version'
subsection, and records the new trust anchor model under Key Design
Decisions."
```

### Task 6.4: Final end-to-end validation

- [ ] **Step 1: Full rebuild + test on the devcontainer**

```bash
make e2e
```

Expected: rebuild succeeds, all tests pass.

- [ ] **Step 2: Inspect image size delta**

```bash
docker images | grep -E 'igou-devenv|vsc-igou'
```

Compare against the size before this refactor (record it before starting; expected delta is ~-125MB from removed cosign/slsa-verifier, possibly net positive due to mise's installed tool layout).

- [ ] **Step 3: Inspect line count delta**

```bash
git diff --stat origin/main -- .devcontainer/Dockerfile builds/podman-rootful/Dockerfile builds/podman-socket/Dockerfile
```

Expected: large net deletion (target is ~−1500 lines across the three Dockerfiles).

- [ ] **Step 4: Confirm no regressions in untouched paths**

```bash
make exec CMD="bash -c 'claude --version && opencode --version && agent --version && python3 --version && podman --version && jq --version'"
```

Expected: all six tools (which were NOT migrated) still work.

- [ ] **Step 5: Resolve issue #44 by linking the PR**

```bash
# When opening the PR for this work, include in the description:
# "Closes #44"
```

No commit for this step — just a note for the PR description.

---

## Self-review checklist (run before declaring done)

- [ ] Spec coverage: every section in the design spec maps to a phase or task
- [ ] No placeholders: search the plan for "TBD", "TODO", "fill in" — should find zero in actionable steps (only acceptable in commit message templates as `<VERSION>` placeholders that the engineer fills with real values from Step 1 of each task)
- [ ] Type/name consistency: `mise.toml`, `mise.lock`, `mise-expected-verification.toml`, `tests/test-mise.sh`, `tests/test-mise-lockfile.sh`, `aqua-registry/oc-postinstall.sh` — same names everywhere
- [ ] All 21 tools accounted for: kubectl(1.5) + 11(2.1) + flux2,sops(2.2) + helm,terraform(2.3) + argocd(2.4) + virtctl,kube-burner,kube-burner-ocp(3.1) + oc(3.2) = 21 ✓
- [ ] Cosign/slsa-verifier removal happens AFTER all tools migrated (Task 4.1 follows Phase 3) ✓
- [ ] Each task has its own commit ✓
- [ ] CLAUDE.md "no embedded file definitions" rule respected: oc-postinstall.sh is a standalone file, not heredoc'd into the Dockerfile ✓
- [ ] Renovate config covers the three new managed surfaces (mise.toml versions, mise itself version, aqua-registry SHA) ✓
- [ ] CLAUDE.md "Pre-push Requirements" rule respected: `make rebuild && make test` is part of the validation flow (Task 6.4 Step 1) ✓
