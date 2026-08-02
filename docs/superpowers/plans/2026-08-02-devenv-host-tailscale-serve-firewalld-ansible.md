# Devenv Host Tailscale Serve + Firewalld Ansible Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codify the two manual host changes made on `vscode.igou.systems` on 2026-08-02 — firewalld `3773/tcp` (T3 Code LAN HTTP) and `tailscale serve` (tailnet HTTPS for the t3 desktop app) — into the existing devenv Ansible automation, rolled out via the `devenv_bootstrap` AAP job template. Closes igou-inventory#276.

**Architecture:** Both changes extend `playbooks/devenv/bootstrap.yml` in `igou-ansible` (the playbook the `devenv_bootstrap` AAP template already runs): the firewalld port joins the existing declarative port loop, and Tailscale Serve becomes a new play appended after the tailnet-join import (ordering: serve requires a joined tailscaled). Configuration data (the serve port) lives in `igou-inventory` `group_vars/devenv/tailscale.yml`, following the established split of logic-in-igou-ansible / data-in-igou-inventory. No AAP object changes are needed — the existing job template picks up both repo changes at launch via project/inventory sync.

**Tech Stack:** Ansible (ansible-lint `production` profile, yamllint), `ansible.posix.firewalld`, `tailscale` CLI, AAP (job template `devenv_bootstrap`, project `igou_ansible`, inventory `igou_inventory`, EE `igou-awx-ee`).

## Global Constraints

- Repos: `~/workspace/igou-ansible` (playbook logic), `~/workspace/igou-inventory` (inventory data). Both lint with `make yamllint && make lint` (ansible-lint `--profile=production`); igou-ansible additionally has `make syntax-check`.
- No secrets in git — 1Password `op://` references / `community.general.onepassword` lookups only. This plan introduces **no new secrets**: the tailnet join already uses `lab_external_api_keys/tailscale-oauth-pettingzoo`.
- firewalld tasks must keep the existing gate pattern: skip unless `firewalld.service` is present **and** running (`ansible_facts.services`) so firewalld-less golden-image hosts converge unchanged.
- Every play in `bootstrap.yml` targets `hosts: "{{ ansible_limit | default('none') }}"` — new plays must follow this pattern (the AAP template launches with `ansible_limit`).
- `ansible-lint` production profile: `ansible.builtin.command` tasks need `changed_when` (and a name); handlers/tasks need FQCN module names.
- Current live state (applied manually 2026-08-02, already verified working): firewalld public zone has `3773/tcp`; `tailscale serve status` shows `https://vscode.weasel-alioth.ts.net (tailnet only) |-- / proxy http://127.0.0.1:3773`. Convergence must be **adoptive**: running the playbook against this state reports `ok`, not `changed`.

## Pre-flight: manual steps for David

These are the only steps Ansible cannot do. Items 1–2 are **verification only** (the infrastructure already exists); item 3 is genuinely new.

1. **Tailscale OAuth client (already exists — verify, or recreate if rotated).** The devenv join uses the `pettingzoo` OAuth client, secret stored at `op://lab_external_api_keys/tailscale-oauth-pettingzoo/token`. Verify it still resolves:
   ```bash
   op read 'op://lab_external_api_keys/tailscale-oauth-pettingzoo/token' | head -c 12
   # expect: tskey-client-
   ```
   Only if missing/revoked, recreate: Tailscale admin console → **Settings → OAuth clients → Generate OAuth client** → scope **Keys: Auth Keys (write)** → add `tag:pettingzoo` as a tag the client can own (the tag must exist in the tailnet ACL `tagOwners` with this client as owner) → copy the `tskey-client-…` secret into the 1P item above (field `token`, vault `lab_external_api_keys`). The host `vscode` is already joined and tagged `tag:pettingzoo`, so no re-join is expected.
2. **Tailnet HTTPS certificates (already enabled — verify).** `tailscale serve` needs the tailnet's HTTPS certificates feature. It is already working (a valid `vscode.weasel-alioth.ts.net` cert was minted 2026-08-02). If serve ever errors about certificates: admin console → **DNS → HTTPS Certificates → Enable**.
3. **Join the Windows desktop to the tailnet (new, required to actually use the HTTPS endpoint).** Install Tailscale on the desktop (10.10.10.23), sign in to the `weasel-alioth` tailnet. Afterwards the t3 desktop app connects to `https://vscode.weasel-alioth.ts.net` (pairing token via `make exec CMD="t3 auth pairing create"` in igou-devenv).

---

### Task 1: igou-ansible — open 3773/tcp in the devenv firewalld loop

**Files:**
- Modify: `~/workspace/igou-ansible/playbooks/devenv/bootstrap.yml` (~line 153, task `Open the devenv service ports in firewalld`)

**Interfaces:**
- Produces: firewalld port `3773/tcp` declared for devenv hosts. Task 5's AAP run converges it (expected `ok` on vscode — already applied manually).

- [ ] **Step 1: Create a working branch**

```bash
cd ~/workspace/igou-ansible
git checkout main && git pull
git checkout -b feat/devenv-t3-firewalld-tailscale-serve
```

- [ ] **Step 2: Add the port to the loop**

In `playbooks/devenv/bootstrap.yml`, extend the existing task's comment and loop (keep the `when:` gate untouched):

```yaml
    - name: Open the devenv service ports in firewalld
      # 8080: code-server (post-start in the devcontainer, host network,
      #       password auth + self-signed TLS). 9100: node_exporter (role
      #       below), scraped by UWM/Prometheus. 3773: T3 Code (t3 serve in
      #       the devcontainer post-start, host network, plain HTTP on the
      #       LAN — pairing-token auth; tailnet clients use the Tailscale
      #       Serve HTTPS proxy configured at the end of this playbook).
      become: true
      ansible.posix.firewalld:
        port: "{{ item }}"
        permanent: true
        immediate: true
        state: enabled
      loop:
        - 3773/tcp
        - 8080/tcp
        - 9100/tcp
      when:
        - "'firewalld.service' in ansible_facts.services"
        - ansible_facts.services['firewalld.service'].state == 'running'
```

- [ ] **Step 3: Lint**

```bash
make yamllint && make lint && make syntax-check
```
Expected: all pass (rc 0).

- [ ] **Step 4: Commit**

```bash
git add playbooks/devenv/bootstrap.yml
git commit -m "feat(devenv): open 3773/tcp for T3 Code in the firewalld port loop"
```

---

### Task 2: igou-ansible — Tailscale Serve play appended to bootstrap.yml

**Files:**
- Modify: `~/workspace/igou-ansible/playbooks/devenv/bootstrap.yml` (append after the `Join the devenv host to the tailnet` import at line ~621)

**Interfaces:**
- Consumes: `tailscale_serve_port` (integer, optional — play no-ops when undefined), defined in igou-inventory by Task 3.
- Produces: idempotent tailnet-HTTPS proxy `:443 → http://127.0.0.1:{{ tailscale_serve_port }}` on devenv hosts.

- [ ] **Step 1: Append the serve play**

Add at the end of `playbooks/devenv/bootstrap.yml` (after the tailnet-join `import_playbook` block — ordering matters, serve needs a joined tailscaled):

```yaml
# ---------------------------------------------------------------------------
# Tailscale Serve: terminate tailnet HTTPS for T3 Code. The t3 desktop app
# requires TLS and `t3 serve` has no native cert support, so tailscaled
# proxies https://<magicdns-name>/ (tailnet only, auto-provisioned cert) to
# the plain-HTTP t3 listener on 127.0.0.1:{{ tailscale_serve_port }}.
# Gated on tailscale_serve_port (group_vars/devenv/tailscale.yml); skips
# hosts without it. Adoptive: re-running against an already-configured host
# reports ok. Requires the tailnet HTTPS-certificates feature (enabled
# 2026-08-02). Manual rollback: `tailscale serve --https=443 off`.
# ---------------------------------------------------------------------------
- name: Configure Tailscale Serve for devenv services
  hosts: "{{ ansible_limit | default('none') }}"
  become: true
  gather_facts: false

  tasks:
    - name: Read current tailscale serve config
      ansible.builtin.command: tailscale serve status --json
      register: devenv_tailscale_serve_status
      changed_when: false
      failed_when: false
      when: tailscale_serve_port is defined

    - name: Serve tailnet HTTPS 443 to the local T3 Code port
      ansible.builtin.command: >-
        tailscale serve --bg {{ tailscale_serve_port }}
      when:
        - tailscale_serve_port is defined
        - devenv_tailscale_serve_status.rc == 0
        - ('127.0.0.1:' ~ tailscale_serve_port) not in
          (devenv_tailscale_serve_status.stdout | default(''))
      changed_when: true
```

Notes for the implementer:
- `failed_when: false` on the read: if tailscaled is down/absent (e.g. molecule container), `rc != 0` and the apply task's `rc == 0` guard skips it — the play never fails on hosts without a live tailnet.
- The idempotency check is a substring match on the JSON serve config: an existing proxy to `127.0.0.1:3773` appears verbatim in `tailscale serve status --json` output.

- [ ] **Step 2: Lint**

```bash
cd ~/workspace/igou-ansible && make yamllint && make lint && make syntax-check
```
Expected: pass. (Both `command` tasks carry `changed_when`, satisfying the production profile's `no-changed-when`.)

- [ ] **Step 3: Molecule regression check (existing scenario still converges)**

```bash
molecule test -s playbook-devenv-bootstrap
```
Expected: PASS — the scenario's container has no `tailscale_serve_port` var and no tailscaled, so both new tasks skip. If the scenario is too heavy to run locally, rely on the repo's CI to run it on the PR.

- [ ] **Step 4: Commit and push, open PR**

```bash
git add playbooks/devenv/bootstrap.yml
git commit -m "feat(devenv): manage Tailscale Serve HTTPS proxy for T3 Code"
git push -u origin feat/devenv-t3-firewalld-tailscale-serve
gh pr create --title "feat(devenv): codify T3 Code firewalld port + Tailscale Serve" \
  --body "Codifies the 2026-08-02 manual host changes on vscode.igou.systems: 3773/tcp in the devenv firewalld loop, and an adoptive Tailscale Serve play (443 -> 127.0.0.1:{{ tailscale_serve_port }}) appended after the tailnet join. Pairs with the igou-inventory PR adding tailscale_serve_port. Refs igou-io/igou-inventory#276."
```

---

### Task 3: igou-inventory — declare the serve port for the devenv group

**Files:**
- Modify: `~/workspace/igou-inventory/group_vars/devenv/tailscale.yml`

**Interfaces:**
- Produces: `tailscale_serve_port: 3773` (consumed by Task 2's play).

- [ ] **Step 1: Branch and edit**

```bash
cd ~/workspace/igou-inventory
git checkout main && git pull
git checkout -b feat/devenv-tailscale-serve-port
```

Append to `group_vars/devenv/tailscale.yml`:

```yaml

# Tailscale Serve (playbooks/devenv/bootstrap.yml, final play): terminate
# tailnet HTTPS on :443 and proxy to this local port — T3 Code's plain-HTTP
# listener (t3 serve, devcontainer post-start, host network). The t3 desktop
# app requires TLS; LAN/browser clients use http://vscode.igou.systems:3773
# directly (firewalld 3773/tcp, same bootstrap playbook). Omit/remove this
# var to skip serve configuration entirely.
tailscale_serve_port: 3773
```

- [ ] **Step 2: Lint**

```bash
make yamllint && make lint
```
Expected: pass.

- [ ] **Step 3: Commit and push, open PR**

```bash
git add group_vars/devenv/tailscale.yml
git commit -m "feat(devenv): declare tailscale_serve_port for T3 Code HTTPS"
git push -u origin feat/devenv-tailscale-serve-port
gh pr create --title "feat(devenv): tailscale_serve_port for T3 Code tailnet HTTPS" \
  --body "Data half of igou-io/igou-ansible's Tailscale Serve play: devenv hosts proxy tailnet HTTPS 443 -> 127.0.0.1:3773 (T3 Code). Closes #276."
```

---

### Task 4: Merge both PRs

**Files:** none (GitHub state).

- [ ] **Step 1: Wait for CI on both PRs, then merge** — igou-ansible first (logic tolerates the var being absent), then igou-inventory. Use each repo's normal merge flow (squash; admin-merge only if branch policy blocks and David has authorized it, consistent with today's igou-devenv merges).

- [ ] **Step 2: Confirm issue linkage** — igou-inventory#276 auto-closes via the `Closes #276` in Task 3's PR; verify, and add a closing comment noting rollout is via `devenv_bootstrap` (Task 5).

---

### Task 5: Roll out via the AAP `devenv_bootstrap` job

**Files:** none (AAP runtime).

**Interfaces:**
- Consumes: merged main of both repos; AAP job template `devenv_bootstrap` (project `igou_ansible`, inventory `igou_inventory`, EE `igou-awx-ee`, `ask_variables_on_launch: true`).

- [ ] **Step 1: Sync AAP sources** — In the AAP UI: **Projects → igou_ansible → Sync**, and refresh the `igou_inventory` inventory source (Inventories → igou_inventory → Sources → Sync) unless both are configured to update on launch — check the toggles; if "update revision on launch" is set, skip this step.

- [ ] **Step 2: Launch the job** — **Templates → devenv_bootstrap → Launch**; at the variables prompt set:

```yaml
ansible_limit: vscode.igou.systems
```

(No AAP object changes are involved, so `make aap-sync-templates` is NOT needed.)

- [ ] **Step 3: Read the job output for adoptive convergence** — Expected on vscode.igou.systems:
  - `Open the devenv service ports in firewalld` → **ok** for all three ports (3773 was pre-applied manually; `changed` would mean the manual rule was lost).
  - `Read current tailscale serve config` → ok.
  - `Serve tailnet HTTPS 443 to the local T3 Code port` → **skipped** (config already present).
  - Tailnet join play → ok/no re-auth (host already joined + tagged).

- [ ] **Step 4: Post-rollout verification on the host**

```bash
sudo firewall-cmd --list-ports            # expect: 3773/tcp 8080/tcp 9100/tcp
tailscale serve status                    # expect: https://vscode.weasel-alioth.ts.net -> proxy http://127.0.0.1:3773
curl -s http://vscode.igou.systems:3773/.well-known/t3/environment | head -c 80
curl -s --resolve vscode.weasel-alioth.ts.net:443:100.84.111.102 \
  https://vscode.weasel-alioth.ts.net/.well-known/t3/environment | head -c 80
```
Expected: both curls return the t3 environment JSON (`{"environmentId":…`).

- [ ] **Step 5: Destructive re-convergence proof (optional but recommended)** — remove one setting and re-run the job to prove Ansible restores it:

```bash
sudo tailscale serve --https=443 off
sudo firewall-cmd --remove-port=3773/tcp   # runtime only, leave --permanent
```
Re-launch `devenv_bootstrap` (Step 2). Expected: firewalld task **changed** (re-enables), serve task **changed** (re-applies); re-run the Step 4 curls.

---

## Self-Review Notes

- Spec coverage: firewalld (Task 1), tailscale serve (Tasks 2+3), OAuth/user steps (Pre-flight), AAP rollout (Task 5), issue #276 closure (Task 4). No molecule scenario changes needed — new tasks self-skip in that environment (verified reasoning in Task 2 Step 3).
- The `--operator=igou` convenience (manage serve without sudo) was deliberately left out — Ansible owns serve config now; add later only if interactive management is wanted.
- Out of scope: managing Tailscale install/up for the devenv host beyond what the existing join play does (already automated); LE-cert reverse proxy (superseded by the Tailscale approach).
