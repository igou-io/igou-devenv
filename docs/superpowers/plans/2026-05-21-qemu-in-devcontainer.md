# QEMU-in-Devcontainer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add QEMU userspace + libvirt stack to the devcontainer image so the `qemu` provisioner from [ansible-collection-molecule_provisioners#21](https://github.com/david-igou/ansible-collection-molecule_provisioners/pull/21) can spin up VMs from inside the container. Phase 1 enables the process driver (minimum viable); Phase 2 enables the libvirt driver.

**Architecture:** `/dev/kvm` already passes through (devcontainer is `--privileged` with `/dev` bind-mounted). The only gap is the userspace stack inside the image. Phase 1 adds `qemu-kvm` + ISO/disk tooling and verifies the `qemu-system-x86_64` binary path matches what the role expects. Phase 2 adds `libvirt-daemon` + `python3-libvirt` + the `community.libvirt` Galaxy collection, starts `virtqemud` on container start, and joins `igou` to the in-container `libvirt` and `kvm` groups. Phase 3 is an end-to-end smoke test running the PR's molecule scenarios.

**Tech Stack:** CentOS Stream 10 (`dnf`), QEMU/KVM, libvirt, Ansible (`community.libvirt`), Molecule, Docker/Podman, Bash.

**Related work:**
- Upstream PR: [david-igou/ansible-collection-molecule_provisioners#21](https://github.com/david-igou/ansible-collection-molecule_provisioners/pull/21)
- Host-side automation tracked in: [david-igou/ansible-collection-devhost#33](https://github.com/david-igou/ansible-collection-devhost/issues/33) (new `kvm` role)

---

## File Structure

**New files:**
- `.devcontainer/galaxy-requirements.yml` — Ansible Galaxy collection pins (`community.libvirt`). New Dockerfile install step consumes this; Renovate's `ansible-galaxy` manager keeps it bumped.
- `tests/test-qemu.sh` — verifies `qemu-system-x86_64`, `qemu-img`, ISO builder, and (Phase 2) `virsh` / `virtqemud` socket; runs a TCG smoke boot.

**Modified files:**
- `.devcontainer/Dockerfile` — add `qemu-kvm`, `qemu-img`, `edk2-ovmf`, `genisoimage` (Phase 1); add `libvirt-daemon`, `libvirt-daemon-driver-qemu`, `libvirt-daemon-config-network`, `libvirt-client`, `python3-libvirt` and the Galaxy install step (Phase 2); add the `qemu-system-x86_64` compatibility symlink if needed.
- `.devcontainer/post-start.sh` — Phase 2: start `virtqemud` (modular libvirt daemon) on every container start; ensure `igou` is in `libvirt` and `kvm` groups (mirrors the existing docker-socket pattern).
- `tests/run-all.sh` — wire in `test-qemu.sh`.
- `tests/test-tools.sh` — add `qemu-system-x86_64`, `qemu-img`, `virsh` to the TOOLS map.
- `Makefile` — add `test-qemu` target; include it in `test-all`.
- `.devcontainer/requirements.txt` — no change (Galaxy collections are not pip-managed).
- `renovate.json` — add an `ansible-galaxy` manager entry if not already covered by the default config.
- `CLAUDE.md` — document the new tooling layer (Galaxy collections) in the install-layer table.
- `.devcontainer/CLAUDE.md` — note QEMU availability in the "What this container is" section.

**Untouched:**
- `devcontainer.json` — `/dev` bind-mount and `--privileged` already give `/dev/kvm` access. No new `--device` flags or capabilities needed.

---

## Phase 0: Verify Package Availability

Before editing the Dockerfile, confirm the exact CentOS Stream 10 package names. CS10 dropped some EPEL packages and renamed others vs. CS9.

### Task 0.1: Resolve CS10 package names for QEMU + libvirt + ISO tooling

**Files:**
- Read-only investigation. Document findings inline below.

- [ ] **Step 1: Spin up a throwaway CS10 container and probe `dnf`**

Run:
```bash
podman run --rm -it quay.io/centos/centos:stream10 bash -lc '
  dnf install -y epel-release >/dev/null 2>&1 || true
  for p in qemu-kvm qemu-img qemu-system-x86 qemu-system-x86-core \
           libvirt libvirt-daemon libvirt-daemon-driver-qemu \
           libvirt-daemon-config-network libvirt-client \
           python3-libvirt edk2-ovmf genisoimage xorriso \
           cloud-utils cloud-init; do
    dnf info "$p" 2>/dev/null | awk -v p="$p" "/^Name/ {found=1; print p, \"AVAILABLE\"} END {if(!found) print p, \"MISSING\"}" | head -1
  done
'
```

Expected output: each package marked `AVAILABLE` or `MISSING`. Record results in task 0.2.

- [ ] **Step 2: Confirm the QEMU binary path on CS10**

Run:
```bash
podman run --rm -it quay.io/centos/centos:stream10 bash -lc '
  dnf install -y qemu-kvm >/dev/null 2>&1
  rpm -ql qemu-kvm | grep -E "qemu-(kvm|system-x86_64)$"
'
```

Expected: identify whether the role's expected `qemu-system-x86_64` ships at `/usr/bin/qemu-system-x86_64`, or only as `/usr/libexec/qemu-kvm`. If the latter, Phase 1 must include a symlink.

- [ ] **Step 3: Record findings**

Edit this plan inline (this section) with the resolved package names and the binary path. Subsequent tasks reference these names.

**Findings (fill in during execution):**
- `qemu-kvm`: AVAILABLE (appstream, v10.1.0) — binary ships at `/usr/libexec/qemu-kvm`, not `/usr/bin/qemu-system-x86_64`
- `qemu-img`: AVAILABLE (appstream, v10.1.0, separate package from `qemu-kvm`) — ships at `/usr/bin/qemu-img`
- `qemu-system-x86`: MISSING on CS10 (not in base, appstream, or EPEL) — use `qemu-kvm` instead; the x86 emulation packages were reorganized upstream
- `qemu-system-x86-core`: MISSING on CS10 (not in base, appstream, or EPEL) — same upstream reorganization; `qemu-kvm` is the correct CS10 equivalent
- `libvirt`: AVAILABLE (appstream) — meta-package that pulls in the full libvirt stack; use this to avoid tracking sub-packages individually if libvirt is needed
- `libvirt-daemon`: AVAILABLE (appstream)
- `libvirt-daemon-driver-qemu`: AVAILABLE (appstream) — QEMU driver for libvirt; required when libvirt manages QEMU/KVM guests
- `libvirt-daemon-config-network`: AVAILABLE (appstream) — default NAT network config for libvirt; needed if the role uses libvirt networking
- `libvirt-client`: AVAILABLE (appstream) — provides `virsh` and client libs; install if the role uses `virsh` commands
- `python3-libvirt`: AVAILABLE (appstream)
- `cloud-utils` (provides `cloud-localds`): MISSING on CS10 (not in base, EPEL, or appstream) — substitute: `xorriso -as mkisofs` or `genisoimage` (see below); `cloud-init` package is available but does not provide `cloud-localds`
  - `cloud-utils-growpart`: AVAILABLE (appstream) — useful for disk resizing (growpart) but does not provide `cloud-localds`; separate package from `cloud-utils`
- `genisoimage`: AVAILABLE but EPEL-only — **decision: install from EPEL** (EPEL is already enabled in the Dockerfile, so no new dependency). The role's `_seed_iso.yml` calls `genisoimage` by name; `xorriso` is also in the image as a backstop.
- QEMU binary path: `/usr/libexec/qemu-kvm` (confirmed — `qemu-kvm` package installs `(contains no files)` to the RPM file list for `/usr/bin`, the binary is at `/usr/libexec/qemu-kvm` only)
- Symlink needed: **yes** — Phase 1 Task 1.2 must add `RUN ln -sf /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64`

- [ ] **Step 4: Commit findings**

```bash
git add docs/superpowers/plans/2026-05-21-qemu-in-devcontainer.md
git commit -m "docs(plan): record CS10 package resolution for qemu/libvirt"
```

---

## Phase 1: Process Driver

Goal: `qemu-system-x86_64 --version` works inside the devcontainer, and the role's `_create_process.yml` task path can launch a guest with KVM acceleration.

### Task 1.1: Add a failing test for the QEMU binary

**Files:**
- Create: `tests/test-qemu.sh`

- [ ] **Step 1: Create the test script with Phase 1 checks only**

Write `tests/test-qemu.sh`:
```bash
#!/usr/bin/env bash
# Verify QEMU userspace and (Phase 2) libvirt stack inside the devcontainer.
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  [OK] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "==> Verifying QEMU userspace..."

# Phase 1 binaries
declare -A QEMU_TOOLS=(
    [qemu-system-x86_64]="qemu-system-x86_64 --version"
    [qemu-img]="qemu-img --version"
    [genisoimage]="genisoimage --version"
)

for tool in $(echo "${!QEMU_TOOLS[@]}" | tr ' ' '\n' | sort); do
    if version=$(${QEMU_TOOLS[$tool]} 2>&1 | head -1) && [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool"
    fi
done

# /dev/kvm reachability (TCG fallback is fine, but we want to know which we got)
echo ""
echo "==> Verifying /dev/kvm..."
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm is a readable+writable char device"
else
    echo "  [WARN] /dev/kvm not accessible — guests will fall back to TCG (slow)"
fi

# Tiny TCG smoke boot — confirms qemu-system-x86_64 actually runs.
# `-kernel /dev/null` makes QEMU exit immediately with a controlled error.
echo ""
echo "==> Smoke-booting QEMU under TCG..."
if timeout 10 qemu-system-x86_64 -accel tcg -nographic -no-reboot \
       -kernel /dev/null -display none </dev/null >/tmp/qemu-smoke.log 2>&1; then
    ok "qemu-system-x86_64 launched and exited cleanly"
else
    rc=$?
    # rc=1 with "kernel too short" or "no bootable device" is the success signal.
    if grep -qE "kernel.*too short|No bootable device|Could not load" /tmp/qemu-smoke.log; then
        ok "qemu-system-x86_64 launched (got expected boot failure)"
    else
        fail "qemu-system-x86_64 smoke boot failed (rc=$rc): $(head -3 /tmp/qemu-smoke.log)"
    fi
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/test-qemu.sh
```

- [ ] **Step 3: Run against current container — verify it fails**

```bash
make exec CMD="/workspace/igou-devenv/tests/test-qemu.sh"
```

Expected: FAIL on `qemu-system-x86_64`, `qemu-img`, `genisoimage` (none installed yet).

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/test-qemu.sh
git commit -m "test(qemu): add failing QEMU userspace verification"
```

### Task 1.2: Add QEMU packages to the Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile` — the `dnf install -y` block at line 24 (the long apt-equivalent list)

- [ ] **Step 1: Add packages to the existing dnf block**

Insert these lines into the alphabetically-grouped `dnf install -y` list in `.devcontainer/Dockerfile` (use the exact names resolved in Task 0.1; the names below are the expected defaults):

```dockerfile
    qemu-kvm \
    qemu-img \
    edk2-ovmf \
    genisoimage \
```

Place them in the existing alphabetical order (e.g., `qemu-*` after `python3-netaddr`, `edk2-ovmf` after the `dnf`-adjacent block, `genisoimage` after `gnupg2`).

> **Per Phase 0 findings**: `cloud-utils` is MISSING on CS10 (no base / EPEL / appstream package) and is therefore dropped from this snippet. `cloud-localds` will not be available; the upstream qemu role's `_seed_iso.yml` falls back to `genisoimage`, which is reachable because EPEL is already enabled at the top of the Dockerfile.

- [ ] **Step 2: Add the QEMU binary symlink (required per Phase 0 findings)**

Task 0.1 confirmed the `qemu-kvm` package on CS10 ships the binary only at `/usr/libexec/qemu-kvm`, so append this RUN line right after the dnf block:

```dockerfile
# CS10 ships qemu-kvm at /usr/libexec/qemu-kvm. The molecule_provisioners
# qemu role launches `qemu-system-x86_64` directly; expose it on PATH.
RUN ln -sf /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64
```

- [ ] **Step 3: Rebuild the devcontainer**

```bash
make rebuild
```

Expected: clean build. If `dnf install` fails for any new package, revisit Task 0.1 findings.

- [ ] **Step 4: Run the QEMU test — verify it passes**

```bash
make exec CMD="/workspace/igou-devenv/tests/test-qemu.sh"
```

Expected: PASS on all Phase 1 checks. `/dev/kvm` either accessible (PASS) or warns (acceptable on hosts without hw virt).

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): install qemu-kvm + qemu-img + iso tooling for process-driver molecule scenarios"
```

### Task 1.3: Wire the QEMU test into the standard suite

**Files:**
- Modify: `tests/run-all.sh`
- Modify: `tests/test-tools.sh:17-36` (the `TOOLS` associative array)
- Modify: `Makefile:9,55,61` (PHONY list, test-all target, new test-qemu target)

- [ ] **Step 1: Add qemu-system-x86_64 and qemu-img to test-tools.sh TOOLS map**

Edit `tests/test-tools.sh`, inside the `declare -A TOOLS=(` block, add:
```bash
    [qemu-system-x86_64]="qemu-system-x86_64 --version"
    [qemu-img]="qemu-img --version"
```

- [ ] **Step 2: Add the test-qemu Make target**

Edit `Makefile`. Update the `.PHONY` line at line 9 to include `test-qemu`:
```makefile
.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env test-mise test-mise-lockfile test-qemu clean rebuild help renovate-validate renovate-dry-run sbom sbom-devcontainer e2e opencode-build mise-lock
```

Update the `test-all` target at line 55:
```makefile
test-all: test-tools test-podman test-env test-mise-lockfile test-mise test-qemu
```

Add a new target right after `test-mise`:
```makefile
## Verify QEMU userspace (and libvirt stack once Phase 2 lands)
test-qemu:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-qemu.sh
```

- [ ] **Step 3: Add test-qemu invocation to tests/run-all.sh**

Locate the section of `tests/run-all.sh` that invokes each test script and append:
```bash
echo ""
echo "=== test-qemu ==="
bash "$(dirname "$0")/test-qemu.sh"
```

(Match the existing pattern — open `tests/run-all.sh` first if unsure.)

- [ ] **Step 4: Run the full test suite**

```bash
make test
```

Expected: all suites pass including `test-qemu`.

- [ ] **Step 5: Commit**

```bash
git add tests/test-tools.sh tests/run-all.sh Makefile
git commit -m "test: wire test-qemu into run-all and test-tools"
```

### Task 1.4: Document the Phase 1 layer

**Files:**
- Modify: `CLAUDE.md` — the "Tool installation layers" table around line 49
- Modify: `.devcontainer/CLAUDE.md` — the "What this container is" bullets

- [ ] **Step 1: Update CLAUDE.md's tool-layer table**

In the "Tool installation layers" table, the existing `Dockerfile (apt)` row already covers dnf packages. Add a row note or extend the existing row to mention `qemu-kvm, qemu-img, genisoimage, edk2-ovmf` as part of the dnf-installed virtualization stack. Single-line edit; don't add a new row.

Then in "Key Design Decisions" add a bullet:
```markdown
- **QEMU available in-container**: `qemu-kvm`, `qemu-img`, `genisoimage`, and `edk2-ovmf` are installed so the `qemu` provisioner from [`ansible-collection-molecule_provisioners`](https://github.com/david-igou/ansible-collection-molecule_provisioners) can launch process-driver guests. `qemu-system-x86_64` is exposed via a symlink to `/usr/libexec/qemu-kvm` (CS10 doesn't ship the canonical binary name). `cloud-utils`/`cloud-localds` are unavailable on CS10, so seed-ISO building uses `genisoimage` (EPEL) directly. `/dev/kvm` is accessible via the existing `/dev` bind-mount + `--privileged` runArgs; no extra runtime config is needed. Host-side prep (kernel module load, `/dev/kvm` permissions) is tracked in [`ansible-collection-devhost#33`](https://github.com/david-igou/ansible-collection-devhost/issues/33).
```

- [ ] **Step 2: Update .devcontainer/CLAUDE.md**

Add a bullet to "What this container is":
```markdown
- QEMU userspace available (`qemu-system-x86_64`, `qemu-img`) — for running molecule scenarios that use the `qemu` provisioner. `/dev/kvm` passes through under `--privileged`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md .devcontainer/CLAUDE.md
git commit -m "docs: document qemu userspace in the devcontainer"
```

### Task 1.5: Phase 1 acceptance — push and verify

- [ ] **Step 1: Full rebuild + test**

```bash
make rebuild && make test
```

Expected: green across the board, including `test-qemu`.

- [ ] **Step 2: Stop here for review**

Tag this commit for visibility:
```bash
git log --oneline | head -5
```

Confirm with the user before proceeding to Phase 2. Phase 2 is independently useful — Phase 1 is enough for the process driver scenarios in PR #21.

---

## Phase 2: Libvirt Driver

Goal: `community.libvirt` modules can talk to `virtqemud` from inside the container, with `igou` in the `libvirt` and `kvm` groups, and the daemon started on every container start.

### Task 2.1: Add a failing test for the libvirt stack

**Files:**
- Modify: `tests/test-qemu.sh`

- [ ] **Step 1: Append libvirt checks to test-qemu.sh**

Add this block to `tests/test-qemu.sh`, before the final `Results:` line:

```bash
echo ""
echo "==> Verifying libvirt stack..."

declare -A LIBVIRT_TOOLS=(
    [virsh]="virsh --version"
    [virtqemud]="virtqemud --version"
)

for tool in $(echo "${!LIBVIRT_TOOLS[@]}" | tr ' ' '\n' | sort); do
    if version=$(${LIBVIRT_TOOLS[$tool]} 2>&1 | head -1) && [ -n "$version" ]; then
        ok "$tool — $version"
    else
        fail "$tool"
    fi
done

# Python libvirt binding — community.libvirt requires this
if python3 -c 'import libvirt' 2>/dev/null; then
    ok "python3-libvirt bindings importable"
else
    fail "python3-libvirt bindings importable"
fi

# Galaxy collection
if ansible-galaxy collection list community.libvirt 2>/dev/null | grep -q community.libvirt; then
    ok "community.libvirt collection installed"
else
    fail "community.libvirt collection installed"
fi

# Group membership
for g in libvirt kvm; do
    if id -nG | grep -qw "$g"; then
        ok "igou is a member of $g group"
    else
        fail "igou is a member of $g group"
    fi
done

# virtqemud socket reachable (daemon started by post-start.sh)
echo ""
echo "==> Verifying virtqemud socket..."
if virsh -c qemu:///system list >/dev/null 2>&1; then
    ok "virsh can talk to qemu:///system"
else
    fail "virsh can talk to qemu:///system"
fi
```

- [ ] **Step 2: Run — verify the new checks fail**

```bash
make exec CMD="/workspace/igou-devenv/tests/test-qemu.sh"
```

Expected: Phase 1 checks still PASS, Phase 2 checks FAIL.

- [ ] **Step 3: Commit**

```bash
git add tests/test-qemu.sh
git commit -m "test(qemu): add failing libvirt-stack verification"
```

### Task 2.2: Add libvirt packages to the Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile` — the same `dnf install -y` block

- [ ] **Step 1: Add libvirt packages**

Insert these into the alphabetical dnf list (verify exact names against Task 0.1 findings):
```dockerfile
    libvirt-client \
    libvirt-daemon \
    libvirt-daemon-config-network \
    libvirt-daemon-driver-qemu \
    python3-libvirt \
```

- [ ] **Step 2: Rebuild and verify libvirt binaries now exist**

```bash
make rebuild
make exec CMD="virsh --version && virtqemud --version && python3 -c 'import libvirt; print(libvirt.__version__)'"
```

Expected: all three print versions.

- [ ] **Step 3: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): install libvirt stack for libvirt-driver molecule scenarios"
```

### Task 2.3: Install community.libvirt collection via Galaxy

**Files:**
- Create: `.devcontainer/galaxy-requirements.yml`
- Modify: `.devcontainer/Dockerfile` — new RUN step

- [ ] **Step 1: Create the Galaxy manifest**

Write `.devcontainer/galaxy-requirements.yml`:
```yaml
---
# Ansible Galaxy collections baked into the devcontainer image.
# Renovate manages version bumps via the ansible-galaxy manager.
collections:
  - name: community.libvirt
    version: ">=1.3.0,<2.0.0"
```

- [ ] **Step 2: Add a Dockerfile RUN step that installs the collection system-wide**

Place this block after the `pip install ... requirements.txt` block in `.devcontainer/Dockerfile` (around line 197-199):

```dockerfile
# ---------------------------------------------------------------------------
# Ansible Galaxy collections — pinned via galaxy-requirements.yml
# Installed system-wide so all users (and CI) get the same collections without
# per-shell ansible-galaxy invocations. Renovate's ansible-galaxy manager
# handles version bumps.
# ---------------------------------------------------------------------------
COPY .devcontainer/galaxy-requirements.yml /tmp/galaxy-requirements.yml
RUN ansible-galaxy collection install \
        -r /tmp/galaxy-requirements.yml \
        --collections-path /usr/share/ansible/collections && \
    rm /tmp/galaxy-requirements.yml
```

- [ ] **Step 3: Rebuild and verify**

```bash
make rebuild
make exec CMD="ansible-galaxy collection list community.libvirt"
```

Expected: prints `community.libvirt` with a version >= 1.3.0.

- [ ] **Step 4: Commit**

```bash
git add .devcontainer/galaxy-requirements.yml .devcontainer/Dockerfile
git commit -m "feat(devcontainer): install community.libvirt galaxy collection via galaxy-requirements.yml"
```

### Task 2.4: Add igou to libvirt and kvm groups

**Files:**
- Modify: `.devcontainer/Dockerfile` — add group creation + usermod near the existing user-creation block at line 6-12

- [ ] **Step 1: Edit the existing user-creation RUN step**

Locate the `RUN dnf install -y sudo && \` block at line 6. The `useradd` line currently uses `-G wheel`. Change it to:

```dockerfile
    useradd -m -s /bin/bash -u 1000 -g 1000 -G wheel igou && \
```

(no change yet — groups must exist first). Instead, add the group creation and group-add as separate steps **after** the libvirt packages are installed (their post-install creates the `libvirt` and `kvm` groups). Append after the libvirt install in the dnf block:

```dockerfile
# Libvirt packages create libvirt + kvm groups at install time. Add igou
# so it can talk to /var/run/libvirt/virtqemud-sock and open /dev/kvm
# without sudo. (Privileged mode + /dev bind-mount makes /dev/kvm
# world-accessible in practice; this is belt-and-suspenders for the
# socket-permission case and for any future tightening of host permissions.)
RUN usermod -aG libvirt,kvm igou
```

Put this as a new RUN line right after the dnf block.

- [ ] **Step 2: Rebuild and verify group membership**

```bash
make rebuild
make exec CMD="id -nG"
```

Expected: output includes `libvirt` and `kvm`.

- [ ] **Step 3: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): add igou to libvirt and kvm groups"
```

### Task 2.5: Start virtqemud on container start

**Files:**
- Modify: `.devcontainer/post-start.sh` — add a new section after the docker socket block (around line 71)

- [ ] **Step 1: Append a virtqemud-start block to post-start.sh**

Add this after the docker-socket section (line 71) and before the Claude config restore block:

```bash
# ---------------------------------------------------------------------------
# Start virtqemud (modular libvirt daemon) so community.libvirt modules and
# `virsh -c qemu:///system` work inside the container. systemd is not running
# here, so we start virtqemud directly as a background process if it isn't
# already running. Idempotent: skips if already up.
# ---------------------------------------------------------------------------
if command -v virtqemud >/dev/null 2>&1; then
    if ! pgrep -x virtqemud >/dev/null 2>&1; then
        echo "==> Starting virtqemud..."
        sudo mkdir -p /var/run/libvirt /var/log/libvirt
        sudo virtqemud --daemon
        # Wait up to 3s for the socket to appear
        for _ in 1 2 3; do
            [ -S /var/run/libvirt/virtqemud-sock ] && break
            sleep 1
        done
        if [ -S /var/run/libvirt/virtqemud-sock ]; then
            echo "    virtqemud socket ready at /var/run/libvirt/virtqemud-sock"
        else
            echo "    WARNING: virtqemud socket did not appear within 3s"
        fi
    else
        echo "==> virtqemud already running"
    fi
fi
```

- [ ] **Step 2: Reload the container (no rebuild) to fire post-start.sh**

```bash
make restart
```

Or, if `make restart` would rebuild:
```bash
make exec CMD="/workspace/igou-devenv/.devcontainer/post-start.sh"
```

- [ ] **Step 3: Verify the socket is up**

```bash
make exec CMD="ls -la /var/run/libvirt/virtqemud-sock && virsh -c qemu:///system list"
```

Expected: socket exists, `virsh list` prints the (empty) domain list header without error.

- [ ] **Step 4: Run the full QEMU test**

```bash
make exec CMD="/workspace/igou-devenv/tests/test-qemu.sh"
```

Expected: every check passes, including `virsh can talk to qemu:///system`.

- [ ] **Step 5: Lint post-start.sh**

```bash
shellcheck .devcontainer/post-start.sh
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add .devcontainer/post-start.sh
git commit -m "feat(devcontainer): start virtqemud in post-start.sh for libvirt-driver scenarios"
```

### Task 2.6: Update test-tools.sh and docs for Phase 2

**Files:**
- Modify: `tests/test-tools.sh:17-36`
- Modify: `CLAUDE.md` — Key Design Decisions
- Modify: `.devcontainer/CLAUDE.md`

- [ ] **Step 1: Add libvirt tools to test-tools.sh TOOLS map**

Inside the `declare -A TOOLS=(` block in `tests/test-tools.sh`, add:
```bash
    [virsh]="virsh --version"
    [virtqemud]="virtqemud --version"
```

- [ ] **Step 2: Update CLAUDE.md design decision**

Replace the Phase 1 bullet about QEMU availability with:
```markdown
- **QEMU available in-container**: `qemu-kvm`, `qemu-img`, `genisoimage`, `edk2-ovmf`, `libvirt-daemon`, `libvirt-client`, `python3-libvirt`, and the `community.libvirt` Galaxy collection are baked into the image so the `qemu` provisioner from [`ansible-collection-molecule_provisioners`](https://github.com/david-igou/ansible-collection-molecule_provisioners) can launch both process-driver and libvirt-driver guests. `/dev/kvm` is accessible via the existing `/dev` bind-mount + `--privileged` runArgs. `virtqemud` is started by `post-start.sh` on every container start. Host-side prep (kernel module load, `/dev/kvm` permissions) is tracked in [`ansible-collection-devhost#33`](https://github.com/david-igou/ansible-collection-devhost/issues/33).
```

- [ ] **Step 3: Update .devcontainer/CLAUDE.md bullet**

Replace the Phase 1 QEMU bullet with:
```markdown
- QEMU + libvirt available (`qemu-system-x86_64`, `qemu-img`, `virsh`, `virtqemud`, `community.libvirt` collection) — for running molecule scenarios that use the `qemu` provisioner. `virtqemud` is started on container start; `/dev/kvm` passes through under `--privileged`.
```

- [ ] **Step 4: Add a new tool-installation-layer row to CLAUDE.md**

In the "Tool installation layers" table, add a row:
```markdown
| Dockerfile (galaxy) | community.libvirt (and future Ansible collections) | `.devcontainer/galaxy-requirements.yml` |
```

- [ ] **Step 5: Run full test + lint**

```bash
make test
shellcheck .devcontainer/post-start.sh .devcontainer/post-create.sh .devcontainer/init.sh dotfiles/.bashrc
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add tests/test-tools.sh CLAUDE.md .devcontainer/CLAUDE.md
git commit -m "docs+test: document libvirt stack and add virsh/virtqemud to test-tools"
```

### Task 2.7: Confirm Renovate covers the new manifest

**Files:**
- Read: `renovate.json`
- Modify (only if needed): `renovate.json`

- [ ] **Step 1: Validate current Renovate config picks up galaxy-requirements.yml**

```bash
make renovate-validate
GITHUB_TOKEN=$GITHUB_TOKEN make renovate-dry-run 2>&1 | tee /tmp/renovate-dry-run.log
grep -i "galaxy\|community.libvirt" /tmp/renovate-dry-run.log || true
```

Expected: Renovate's `ansible-galaxy` manager detects `community.libvirt`. If it does not, proceed to Step 2; otherwise skip to Step 3.

- [ ] **Step 2: Add an ansible-galaxy manager entry to renovate.json**

Add to the `managers` or `customManagers` section:
```json
{
  "matchManagers": ["ansible-galaxy"],
  "fileMatch": ["(^|/).devcontainer/galaxy-requirements\\.yml$"]
}
```

Re-run `make renovate-validate` to confirm valid JSON.

- [ ] **Step 3: Commit (if changed)**

```bash
git add renovate.json
git commit -m "chore(renovate): cover .devcontainer/galaxy-requirements.yml"
```

If no change was needed, skip the commit.

### Task 2.8: Phase 2 acceptance

- [ ] **Step 1: Full rebuild + test**

```bash
make rebuild && make test
```

Expected: green.

- [ ] **Step 2: Manual sanity — define and undefine a transient domain**

```bash
make exec CMD="virsh -c qemu:///system net-list --all && virsh -c qemu:///system pool-list --all"
```

Expected: lists the `default` network (autostart=no after package install — this is fine; the role creates its own pools/networks per scenario).

- [ ] **Step 3: Confirm with the user before proceeding to Phase 3.**

---

## Phase 3: End-to-End Smoke Test with the Upstream Collection

Goal: prove the devcontainer can actually run the molecule scenarios from PR #21.

### Task 3.1: Clone the collection into the workspace

**Files:**
- No repo edits. Operates against a workspace checkout under `/workspace/`.

- [ ] **Step 1: Clone PR #21 into the host workspace so it bind-mounts into the container**

Run on the host (or in the container — both see `/workspace/`):
```bash
cd ~/workspace
git clone https://github.com/david-igou/ansible-collection-molecule_provisioners.git
cd ansible-collection-molecule_provisioners
gh pr checkout 21
```

- [ ] **Step 2: Confirm the scenarios are present**

```bash
make exec CMD="ls /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu/"
```

Expected: directory listing with the three-VM scenario (libvirt+slirp, process+slirp, libvirt+nat).

### Task 3.2: Run the process-driver scenario

**Files:**
- No repo edits.

- [ ] **Step 1: Run molecule against just the process-driver VM**

```bash
make exec CMD="cd /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu && molecule test -- --limit process-slirp"
```

Adjust the `--limit` value to match the scenario's actual host name (check `molecule.yml`).

Expected: VM creates, converges, destroys cleanly. If KVM is unavailable, the scenario will fall back to TCG and take longer but should still pass.

- [ ] **Step 2: Capture logs on failure**

If anything fails, save the molecule debug output:
```bash
make exec CMD="cd /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu && MOLECULE_DEBUG=1 molecule test -- --limit process-slirp 2>&1 | tee /tmp/molecule-process.log"
```

Triage common issues:
- `qemu-system-x86_64: command not found` → symlink missing or wrong path (Task 1.2 Step 2)
- `Permission denied: /dev/kvm` → host-side issue, devhost#33
- `cloud-localds: command not found` → expected on CS10 (`cloud-utils` is MISSING per Phase 0); the role should fall through to its `genisoimage` path. If it doesn't, check that the role's `_seed_iso.yml` selects the fallback when `cloud-localds` is absent.

### Task 3.3: Run the libvirt-driver scenarios

**Files:**
- No repo edits.

- [ ] **Step 1: Run molecule against the libvirt+slirp VM**

```bash
make exec CMD="cd /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu && molecule test -- --limit libvirt-slirp"
```

Expected: domain defines via `community.libvirt.virt`, boots, SSH succeeds, destroys cleanly.

- [ ] **Step 2: Run the libvirt+NAT VM**

```bash
make exec CMD="cd /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu && molecule test -- --limit libvirt-nat"
```

Expected: passes. If virbr0 collides with host networking under `--network=host`, this will fail with a route or DHCP error — document the result and surface as a follow-up issue (NAT-mode incompatibility with `--network=host` is a known caveat in the previous turn's analysis).

- [ ] **Step 3: Run the full scenario**

```bash
make exec CMD="cd /workspace/ansible-collection-molecule_provisioners/extensions/molecule/qemu && molecule test"
```

Expected: all three VMs pass (or document the NAT caveat from Step 2).

### Task 3.4: Document the smoke-test result

**Files:**
- Modify: this plan document — append a "Phase 3 results" subsection

- [ ] **Step 1: Record what worked and what didn't**

Append to this plan:
```markdown
## Phase 3 Results

- process-slirp: PASS / FAIL — reason
- libvirt-slirp: PASS / FAIL — reason
- libvirt-nat:   PASS / FAIL — reason
- Notes: any deviations from expected behavior, workarounds applied, follow-up issues filed
```

- [ ] **Step 2: Commit the result snapshot**

```bash
git add docs/superpowers/plans/2026-05-21-qemu-in-devcontainer.md
git commit -m "docs(plan): record qemu-in-devcontainer phase 3 smoke-test results"
```

---

## Out-of-Scope (Tracked Elsewhere)

- **Host-side `kvm` role**: kernel module load, `/dev/kvm` permissions, nested-virt option. Filed as [devhost#33](https://github.com/david-igou/ansible-collection-devhost/issues/33).
- **Bridge networking from inside the devcontainer**: the `--network=host` setting collides with libvirt's default `virbr0`. Only matters if the user needs the libvirt-driver's NAT mode. Investigate and file a follow-up issue if Task 3.3 Step 2 fails.
- **PR #21 upstream merge**: this plan does not block on PR #21 being merged — we test against the PR branch via `gh pr checkout` in Task 3.1.

## Acceptance Criteria (Whole Plan)

- [ ] `make rebuild && make test` is green, including `test-qemu`.
- [ ] `qemu-system-x86_64`, `qemu-img`, `virsh`, `virtqemud`, and `python3-libvirt` all work inside the container.
- [ ] `community.libvirt` collection is installed system-wide via `galaxy-requirements.yml`.
- [ ] `virtqemud` starts on container start via `post-start.sh`.
- [ ] At least the process-driver molecule scenario from PR #21 runs to completion inside the devcontainer.
- [ ] [devhost#33](https://github.com/david-igou/ansible-collection-devhost/issues/33) tracks the host-side automation as a separate work item.
