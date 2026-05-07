# Opencode Orchestrator + Local Subagents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `~/.config/opencode/opencode.jsonc` so opencode's `plan` mode runs on GPT-5.5 via OpenRouter, dispatches Task-tool work to `general`/`explore` subagents pinned to the existing local Qwen3-35B endpoint, and follows a superpowers-driven orchestration loop (brainstorming → writing-plans → parallel dispatch).

**Architecture:** All implementation lives in user-config files outside this repo (`~/.config/opencode/`), plus one new env file inside the repo (`envs/openrouter.env`). The standalone `opencode-run` container and the VS Code devcontainer both bind-mount `~/.config/opencode`, so a single set of edits covers both. No Dockerfile or launcher changes.

**Tech Stack:** opencode (CLI), JSONC config, OpenRouter (paid), self-hosted Qwen3-35B-A3B on OpenShift, 1Password CLI for secret resolution, superpowers v5.0.7 (already loaded as opencode plugin).

**Spec:** `docs/superpowers/specs/2026-05-07-opencode-orchestrator-subagents-design.md` (commit `d690893`).

---

## File Structure

In-repo:
- **Create:** `envs/openrouter.env` — single-line 1Password reference for the paid OpenRouter API key. Tracked in git.

User config (outside this repo, on the user's host; mounted into both containers via the existing bind-mount):
- **Create:** `~/.config/opencode/prompts/plan-orchestrator.md` — augments built-in plan-mode prompt with superpowers orchestration discipline.
- **Create:** `~/.config/opencode/prompts/general-executor.md` — augments built-in `general` subagent prompt with TDD/verification rails.
- **Modify:** `~/.config/opencode/opencode.jsonc` — adds the `openrouter` provider, `small_model`, and three agent overrides (`plan`, `general`, `explore`). Existing `llama.cpp` provider, default `model`, and `plugin` array are preserved verbatim.

User config files are not tracked from this repo. Only `envs/openrouter.env` produces a git commit. The `opencode.jsonc` edits get a local `.bak` backup before modification.

## Prerequisites

Before Task 5 (smoke tests) can pass, the user must have a paid OpenRouter API key stored in 1Password at the path `op://claude/openrouter-paid/token`. If the path needs to change, update both `envs/openrouter.env` and the verification commands.

If any task fails catastrophically and `opencode.jsonc` is in a broken state, restore from the backup created in Task 4:
```bash
cp ~/.config/opencode/opencode.jsonc.bak ~/.config/opencode/opencode.jsonc
```

---

## Task 1: Create `envs/openrouter.env`

**Files:**
- Create: `/workspace/igou-devenv/envs/openrouter.env`

- [ ] **Step 1: Inspect the existing `openrouter-free.env` for format reference**

```bash
cat /workspace/igou-devenv/envs/openrouter-free.env
```

Expected: file contents starting with `ANTHROPIC_BASE_URL=...` and `OPENROUTER_API_KEY=op://claude/openrouter-freemodels/token`. Confirms the `op://` reference format and the existing vault layout (`claude` vault, items named per-key).

- [ ] **Step 2: Write the new env file**

Create `/workspace/igou-devenv/envs/openrouter.env` with exactly this content:

```bash
# Paid OpenRouter key for opencode plan-mode orchestrator (GPT-5.5).
# Resolved by `use openrouter` in shell or `opencode-run -e openrouter`.
OPENROUTER_API_KEY=op://claude/openrouter-paid/token
```

- [ ] **Step 3: Verify the file resolves via `op inject` (requires the 1Password item to exist)**

```bash
op inject -i /workspace/igou-devenv/envs/openrouter.env
```

Expected on success: stdout shows `OPENROUTER_API_KEY=sk-or-v1-...` (the actual key value). The two header comment lines are passed through unchanged.

If the 1Password item does not yet exist, you will see an error like:
```
[ERROR] could not resolve "op://claude/openrouter-paid/token": "openrouter-paid" isn't an item in "claude"
```

That error is acceptable at this stage — it confirms the syntax is correct and the only missing piece is the vault item. Document it; the user creates the item before Task 5.

- [ ] **Step 4: Commit**

```bash
cd /workspace/igou-devenv
git add envs/openrouter.env
git commit -m "$(cat <<'EOF'
Add envs/openrouter.env for paid OpenRouter key

Used by opencode plan-mode orchestrator (GPT-5.5). Resolves via
`use openrouter` in the devcontainer shell or `opencode-run -e openrouter`.
The existing openrouter-free.env stays — different key, different purpose.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create the prompts directory and write `plan-orchestrator.md`

**Files:**
- Create: `~/.config/opencode/prompts/plan-orchestrator.md`

- [ ] **Step 1: Create the prompts directory**

```bash
mkdir -p ~/.config/opencode/prompts
```

Verify:
```bash
ls -ld ~/.config/opencode/prompts
```

Expected: directory exists, owned by the current user, mode `drwxr-xr-x` or similar.

- [ ] **Step 2: Write `plan-orchestrator.md`**

Create `~/.config/opencode/prompts/plan-orchestrator.md` with exactly this content:

```markdown
You operate in opencode `plan` mode. You are a superpowers-aware orchestrator.

Hard rules:
- You do not edit, write, or run bash. Those tools are denied for you.
- For any non-trivial task, follow the superpowers skill chain:
    1. superpowers:brainstorming  — refine intent, write a spec.
    2. superpowers:writing-plans  — convert spec to implementation plan.
    3. superpowers:subagent-driven-development +
       superpowers:dispatching-parallel-agents — dispatch via Task tool.
- Prefer parallel dispatch: when a plan has ≥2 steps with no shared state
  or sequential dependency, emit multiple Task calls in a single message.
- Subagents run on a smaller local model (Qwen3-35B). Brief them
  thoroughly: file paths, exact changes, which superpowers skills to use,
  what evidence to return.
- Before declaring a step complete, require evidence in the subagent's
  report (command run, output observed) — not just a claim of success.
```

- [ ] **Step 3: Verify the file**

```bash
wc -l ~/.config/opencode/prompts/plan-orchestrator.md
head -1 ~/.config/opencode/prompts/plan-orchestrator.md
```

Expected: line count ~15, first line `You operate in opencode \`plan\` mode. You are a superpowers-aware orchestrator.`

(No git commit — file is outside the repo.)

---

## Task 3: Write `general-executor.md`

**Files:**
- Create: `~/.config/opencode/prompts/general-executor.md`

- [ ] **Step 1: Write `general-executor.md`**

Create `~/.config/opencode/prompts/general-executor.md` with exactly this content:

```markdown
You are the `general` subagent executing one well-defined task from a
superpowers plan written by the orchestrator.

Required behavior:
- For any code change: follow superpowers:test-driven-development.
  Write the failing test first, watch it fail, implement, watch it pass.
- Before reporting done: invoke superpowers:verification-before-completion.
  Run the verification command, paste the actual output. Do not paraphrase.
- For unexpected failures: invoke superpowers:systematic-debugging.
  Form a hypothesis before changing code.
- Report back with evidence — commands, outputs, file paths and line numbers.
  Not summaries. Not "I made the change." The orchestrator cannot see your
  context; it can only see what you return.
```

- [ ] **Step 2: Verify the file**

```bash
wc -l ~/.config/opencode/prompts/general-executor.md
head -1 ~/.config/opencode/prompts/general-executor.md
```

Expected: line count ~13, first line `You are the \`general\` subagent executing one well-defined task from a`.

(No git commit — file is outside the repo.)

---

## Task 4: Backup and edit `opencode.jsonc`

**Files:**
- Modify: `~/.config/opencode/opencode.jsonc`
- Create: `~/.config/opencode/opencode.jsonc.bak` (backup)

- [ ] **Step 1: Back up the existing config**

```bash
cp ~/.config/opencode/opencode.jsonc ~/.config/opencode/opencode.jsonc.bak
diff ~/.config/opencode/opencode.jsonc ~/.config/opencode/opencode.jsonc.bak
```

Expected: `diff` produces no output (identical files); the `cp` succeeded.

- [ ] **Step 2: Read the current config to confirm starting state**

```bash
cat ~/.config/opencode/opencode.jsonc
```

Expected first non-comment line: `{`. Should contain a `"provider"` block with `"llama.cpp"`, a `"model"` line set to `"llama.cpp/qwen3.6-35b-a3b"`, and a `"plugin"` array. The only top-level keys should be `$schema`, `provider`, `model`, `plugin`. If any expected key is missing OR any unexpected top-level key is present (e.g. `agent`, `small_model`, additional providers, MCP config the user added later), STOP and reconcile with the user before editing — Step 3's whole-file replacement would clobber unknown additions.

- [ ] **Step 3: Replace the file with the merged config**

Write `~/.config/opencode/opencode.jsonc` with exactly this content (the existing `llama.cpp` provider entry and `plugin` array are preserved verbatim from the user's current file; only the new pieces are interleaved):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama.cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (igou.systems)",
      "options": {
        "baseURL": "https://qwen3-35b-a3b-llmkube-system.apps.ocp.igou.systems/v1"
      },
      "models": {
        "qwen3.6-35b-a3b": {
          "name": "Qwen3.6-35B-A3B (local)",
          "limit": { "context": 65536, "output": 32768 },
          "reasoning": true,
          "tools": true,
          "temperature": true,
          "options": { "temperature": 0.7, "top_p": 0.8 }
        }
      }
    },
    "openrouter": {
      "options": {
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "openai/gpt-5.5": {
          "name": "GPT-5.5 (OpenRouter)",
          "tools": true,
          "reasoning": true,
          "options": {
            "reasoning": { "effort": "medium" }
          }
        }
      }
    }
  },
  "model": "llama.cpp/qwen3.6-35b-a3b",
  "small_model": "llama.cpp/qwen3.6-35b-a3b",
  "agent": {
    "plan": {
      "model": "openrouter/openai/gpt-5.5",
      "prompt": "{file:./prompts/plan-orchestrator.md}",
      "permission": {
        "edit":  "deny",
        "write": "deny",
        "bash":  "deny"
      }
    },
    "general": {
      "mode": "subagent",
      "model": "llama.cpp/qwen3.6-35b-a3b",
      "prompt": "{file:./prompts/general-executor.md}"
    },
    "explore": {
      "mode": "subagent",
      "model": "llama.cpp/qwen3.6-35b-a3b"
    }
  },
  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git#v5.0.7"]
}
```

- [ ] **Step 4: Validate the JSONC parses**

JSONC allows comments and trailing commas, which strict `json.loads()` rejects. Use a tolerant parser:

```bash
python3 <<'PYEOF'
import json, re, sys
src = open('/home/igou/.config/opencode/opencode.jsonc').read()
# Strip block comments /* ... */
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
# Strip line comments — only when preceded by whitespace or start-of-line,
# to avoid breaking URLs like https://...
src = re.sub(r'(^|\s)//[^\n]*', r'\1', src)
# Strip trailing commas before } or ]
src = re.sub(r',(\s*[}\]])', r'\1', src)
try:
    data = json.loads(src)
except json.JSONDecodeError as e:
    print(f"FAIL: {e}")
    sys.exit(1)
# Spot-check the new structure
assert 'openrouter' in data['provider'], "missing openrouter provider"
assert data['small_model'] == 'llama.cpp/qwen3.6-35b-a3b', "small_model wrong"
assert data['agent']['plan']['model'] == 'openrouter/openai/gpt-5.5', "plan model wrong"
assert data['agent']['plan']['permission']['edit'] == 'deny', "plan edit not denied"
assert data['agent']['general']['model'] == 'llama.cpp/qwen3.6-35b-a3b', "general model wrong"
assert data['agent']['explore']['model'] == 'llama.cpp/qwen3.6-35b-a3b', "explore model wrong"
print("OK: opencode.jsonc parses and contains expected fields")
PYEOF
```

Expected output: `OK: opencode.jsonc parses and contains expected fields`. Any other output (especially `FAIL: ...` or an `AssertionError`) means the file is wrong; restore from `.bak` and retry.

- [ ] **Step 5: Confirm opencode itself accepts the config**

```bash
opencode --version
```

Expected: prints a version string (e.g. `opencode 0.x.y`) and exits cleanly. Errors mentioning the config file (e.g. `failed to parse opencode.jsonc`, `unknown field`) mean opencode is unhappy with the schema even though Python parsed it. Restore from `.bak` and reconcile.

(No git commit — file is outside the repo.)

---

## Task 5: Smoke test — paid OpenRouter key resolves

**Prerequisite:** the user has created the paid OpenRouter API key and stored it in 1Password at `op://claude/openrouter-paid/token`.

- [ ] **Step 1: Resolve the env file**

```bash
op inject -i /workspace/igou-devenv/envs/openrouter.env
```

Expected: output line `OPENROUTER_API_KEY=sk-or-v1-...` with a real key string after the `=`.

If you see `[ERROR] could not resolve "op://...": ... isn't an item in ...`, the prerequisite is not met — ask the user to create the 1Password item before continuing.

- [ ] **Step 2: Confirm the key gets exported into the shell**

The user's existing `use` function (defined in `dotfiles/.bashrc`, see ADR-0001) reads the env file via `op inject` and exports the variables.

```bash
use openrouter
echo "OPENROUTER_API_KEY length: ${#OPENROUTER_API_KEY}"
```

Expected: a number greater than 50 (real OpenRouter keys are ~70–80 chars).

If the number is `0`, `use` did not export the variable; check that `dotfiles/.bashrc` is sourced in the current shell (`source ~/.bashrc`) and that the function exists (`type use`).

---

## Task 6: Smoke test — plan mode routes to OpenRouter

- [ ] **Step 1: Launch opencode**

```bash
opencode
```

This opens the interactive TUI. Confirm the bottom status bar shows `build` mode by default and the active model is `llama.cpp/qwen3.6-35b-a3b`.

- [ ] **Step 2: Switch to plan mode**

Press `Tab` (or use `/agent plan` / the bound `switch_agent` key) to switch to plan mode. The status bar should now show `plan` and the active model `openrouter/openai/gpt-5.5` (or however opencode renders the qualified name).

- [ ] **Step 3: Send a trivial probe**

Type and submit:

```
What model are you, and what reasoning effort are you running at?
```

Expected: the response references GPT-5.5 (or "OpenAI's GPT-5" in some self-introduction) and acknowledges medium reasoning effort. Latency should feel like a hosted-API call (1–5s before first tokens), not local Qwen3 (which is typically faster on first token via the user's GPU stack but slower on long generations).

- [ ] **Step 4: Confirm the routing in the session log**

Open the opencode session log (TUI default location is `~/.local/share/opencode/sessions/<session-id>/` or check the docs for the current path):

```bash
ls -t ~/.local/share/opencode/sessions/ | head -1
```

Open the most recent session file and grep for the provider:

```bash
SESSION=$(ls -t ~/.local/share/opencode/sessions/ | head -1)
grep -E '"provider"|"model"' ~/.local/share/opencode/sessions/$SESSION/*.json* 2>/dev/null | head -20
```

Expected: at least one match showing `"provider": "openrouter"` or `"model": "openai/gpt-5.5"`. If only `llama.cpp` appears, the agent override isn't taking effect — recheck Task 4 step 3 and Task 4 step 4.

If opencode logs to a different path on this version, the alternate locations to try are `~/.cache/opencode/`, `./opencode-sessions/` (project-local), or `--debug`-mode stdout.

---

## Task 7: Smoke test — build mode still routes to local

- [ ] **Step 1: Switch back to build mode**

In the same opencode session, press `Tab` to return to `build` mode. Status bar should show `build` and active model `llama.cpp/qwen3.6-35b-a3b`.

- [ ] **Step 2: Send the same probe**

```
What model are you?
```

Expected: response identifies as Qwen (or similar — Qwen3 instruct models typically self-identify clearly). Latency profile differs from Step 3 of Task 6.

- [ ] **Step 3: Confirm via session log**

Same grep as Task 6 step 4, but now the most recent agent calls should reference `llama.cpp` provider.

This proves switching modes flips the routing without restarting opencode and without leaking OpenRouter calls into solo work.

---

## Task 8: Smoke test — superpowers loop end-to-end

- [ ] **Step 1: Switch to plan mode and dispatch a real task**

In opencode, switch to `plan` mode. Submit:

```
Add a test to /workspace/igou-devenv/tests/test-tools.sh that verifies `jq` is on PATH. Use the existing TOOLS associative array convention.
```

- [ ] **Step 2: Observe the skill invocations**

Expected behavior, in order:
1. Plan agent (GPT-5.5) announces invoking `superpowers:brainstorming` (the brainstorming skill's HARD-GATE forces it for any creative task, including config additions).
2. After spec/clarification, the agent invokes `superpowers:writing-plans`.
3. The agent emits one or more `Task` tool calls targeting the `general` subagent. The Task call brief should explicitly tell the subagent which superpowers skills to use (e.g. `test-driven-development`, `verification-before-completion`).

If the agent jumps straight to editing without skill announcements, the prompt augmentation (`plan-orchestrator.md`) is not being loaded. Recheck Task 4 step 3 (`"prompt": "{file:./prompts/plan-orchestrator.md}"`) and that the file exists at the referenced path.

- [ ] **Step 3: Confirm the subagent ran on local Qwen3**

After the Task tool returns, grep the session log for the subagent's provider:

```bash
SESSION=$(ls -t ~/.local/share/opencode/sessions/ | head -1)
grep -E '"agent":\s*"general"' ~/.local/share/opencode/sessions/$SESSION/*.json* 2>/dev/null -A 2 | head -20
```

Expected: matches show the subagent ran with `provider: llama.cpp` and `model: qwen3.6-35b-a3b`, not OpenRouter.

- [ ] **Step 4: Confirm evidence-bearing report**

The plan agent's response after the Task call returns should quote actual command output (e.g. `grep` results from the test file, or the `bash tests/test-tools.sh` exit/diff), not just a paraphrased "I added the test." If the report is paraphrased, the `general-executor.md` prompt is not being loaded — recheck Task 4 step 3 (`"prompt": "{file:./prompts/general-executor.md}"`) on the `general` agent block.

- [ ] **Step 5: Discard the actual change**

The smoke test produced an unwanted edit to `tests/test-tools.sh`. Revert it (do not commit):

```bash
cd /workspace/igou-devenv
git diff tests/test-tools.sh   # confirm what changed
git checkout -- tests/test-tools.sh
git status                      # confirm clean
```

This task verifies the loop works; the actual `jq` test is out of scope for this plan.

---

## Task 9: Smoke test — parallel dispatch (optional)

This task is optional. Skip if the user accepted the spec's note that "parallel dispatch becomes a no-op rather than an error" if the Qwen3 endpoint is single-replica.

- [ ] **Step 1: Submit a task with two independent steps**

In `plan` mode, submit:

```
Two independent tasks:
1. Search /workspace/igou-devenv for any file containing the string "TODO" and report counts per file.
2. Search /workspace/igou-devenv for any file containing the string "FIXME" and report counts per file.

Dispatch them in parallel; they don't share state.
```

- [ ] **Step 2: Confirm parallel Task calls**

Watch the plan agent's response. Expected: a single message containing two `Task` tool calls (visible as two simultaneous tool-use blocks), not two sequential turns. The `dispatching-parallel-agents` skill should be announced.

If the agent dispatches sequentially, the parallelism prompt directive isn't taking — but this is acceptable per the spec; revisit only if the user wants to enforce it harder.

- [ ] **Step 3: Confirm both subagents ran on local Qwen3**

```bash
SESSION=$(ls -t ~/.local/share/opencode/sessions/ | head -1)
grep -E '"agent":\s*"(general|explore)"' ~/.local/share/opencode/sessions/$SESSION/*.json* 2>/dev/null -A 2 | grep -E 'provider|model' | head -10
```

Expected: both subagent invocations show `llama.cpp` / `qwen3.6-35b-a3b`. No OpenRouter calls except for the orchestrator's reasoning turns.

---

## Task 10 (Amendment): Narrow plan-mode permissions to allow superpowers artifacts

**Why this task exists:** The original Task 4 set `plan` agent permissions to a blanket `edit/write/bash: deny`. Smoke testing surfaced that this conflicts with the `superpowers:brainstorming` and `superpowers:writing-plans` skills, both of which require the agent running them to write spec/plan files (`docs/superpowers/specs/...md`, `docs/superpowers/plans/...md`) and `git add`/`git commit` those artifacts. Without this amendment, the orchestrator must Tab-switch to `build` mode mid-session — which loses GPT-5.5 context and fails the orchestrator role at exactly the moments it should be active.

opencode supports per-agent path-globbed permissions on both `edit` and `bash` (last matching rule wins, see https://opencode.ai/docs/permissions/). The amendment uses that to allow narrow exceptions for the orchestrator's own artifacts while keeping all code/test/build/run paths denied.

**Files:**
- Modify: `~/.config/opencode/opencode.jsonc`
- Modify: `~/.config/opencode/prompts/plan-orchestrator.md`

- [ ] **Step 1: Replace the `plan` agent's `permission` block**

In `~/.config/opencode/opencode.jsonc`, find the `agent.plan.permission` block and replace it. The whole `plan` agent block becomes:

```jsonc
"plan": {
  "model": "openrouter/openai/gpt-5.5",
  "prompt": "{file:./prompts/plan-orchestrator.md}",
  "permission": {
    "edit": {
      "*": "deny",
      "docs/superpowers/specs/**": "allow",
      "docs/superpowers/plans/**": "allow"
    },
    "bash": {
      "*": "deny",
      "git status*": "allow",
      "git diff*": "allow",
      "git log*": "allow",
      "git add docs/superpowers/*": "allow",
      "git commit*": "allow"
    }
  }
}
```

Notes on the change:
- `edit` becomes object-form. opencode treats `edit` as covering `edit`, `write`, and `patch` — a single key blocks all mutation primitives. The catch-all `*: deny` runs first, the `docs/superpowers/{specs,plans}/**` allows override (last matching rule wins).
- `bash` becomes object-form with five allowed patterns: read-only git inspection (status, diff, log) plus the two write commands needed to commit orchestrator artifacts (`git add docs/superpowers/*`, `git commit*`).
- The previous explicit `write: "deny"` entry is removed — it was a no-op (opencode has no standalone `write` permission key).
- Wildcard patterns require an argument per opencode docs; trailing `*` covers both `git status` and `git status -s`.

- [ ] **Step 2: Validate JSONC parses and opencode accepts the config**

```bash
python3 <<'PYEOF'
import json, re, sys
src = open('/home/igou/.config/opencode/opencode.jsonc').read()
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'(^|\s)//[^\n]*', r'\1', src)
src = re.sub(r',(\s*[}\]])', r'\1', src)
data = json.loads(src)
p = data['agent']['plan']['permission']
assert isinstance(p['edit'], dict) and p['edit']['*'] == 'deny'
assert p['edit']['docs/superpowers/specs/**'] == 'allow'
assert p['edit']['docs/superpowers/plans/**'] == 'allow'
assert isinstance(p['bash'], dict) and p['bash']['*'] == 'deny'
assert p['bash']['git commit*'] == 'allow'
assert 'write' not in p, "stale write key still present"
print("OK: plan.permission updated correctly")
PYEOF
```

Then confirm opencode itself still loads the config (use `opencode-run` if `opencode` is not on PATH in the current devcontainer):

```bash
opencode-run -- --version 2>&1 | tail -3
```

Expected: a version string (e.g. `1.14.33`) and no config-error output.

- [ ] **Step 3: Update `~/.config/opencode/prompts/plan-orchestrator.md`**

The existing prompt's first hard rule says "You do not edit, write, or run bash. Those tools are denied for you." That is now incorrect — the orchestrator can edit/write within `docs/superpowers/**` and run a small set of git commands. Replace the first hard-rule bullet with:

```markdown
- You write your own spec and plan artifacts under `docs/superpowers/specs/`
  and `docs/superpowers/plans/`, and you may `git add` / `git commit` those
  paths. You may run read-only git inspection (`git status`, `diff`, `log`).
  Every other file edit, every other bash command, is denied for you —
  dispatch all code/test/build/run work to subagents via the Task tool.
```

Verify the file still has 19–20 lines and no other content changed:

```bash
wc -l ~/.config/opencode/prompts/plan-orchestrator.md
diff ~/.config/opencode/prompts/plan-orchestrator.md - <<'EOF' || true
You operate in opencode `plan` mode. You are a superpowers-aware orchestrator.

Hard rules:
- You write your own spec and plan artifacts under `docs/superpowers/specs/`
  and `docs/superpowers/plans/`, and you may `git add` / `git commit` those
  paths. You may run read-only git inspection (`git status`, `diff`, `log`).
  Every other file edit, every other bash command, is denied for you —
  dispatch all code/test/build/run work to subagents via the Task tool.
- For any non-trivial task, follow the superpowers skill chain:
    1. superpowers:brainstorming  — refine intent, write a spec.
    2. superpowers:writing-plans  — convert spec to implementation plan.
    3. superpowers:subagent-driven-development +
       superpowers:dispatching-parallel-agents — dispatch via Task tool.
- Prefer parallel dispatch: when a plan has ≥2 steps with no shared state
  or sequential dependency, emit multiple Task calls in a single message.
- Subagents run on a smaller local model (Qwen3-35B). Brief them
  thoroughly: file paths, exact changes, which superpowers skills to use,
  what evidence to return.
- Before declaring a step complete, require evidence in the subagent's
  report (command run, output observed) — not just a claim of success.
EOF
```

`diff` should produce no output.

- [ ] **Step 4: Re-run the superpowers loop smoke test (Task 8 with the new permissions)**

Switch to `plan` mode in opencode and submit a task that exercises the brainstorming → writing-plans flow. The orchestrator should now write its own spec/plan files without prompting you to switch modes. If you observe the orchestrator (a) writing a spec file under `docs/superpowers/specs/...`, (b) successfully `git add`/`git commit`-ing it, then dispatching to subagents, the amendment is working as designed.

If `edit` denials surface for the `docs/superpowers/...` paths the orchestrator is supposed to be allowed to write, the path glob is wrong (most likely the working directory root differs from what the glob assumes — confirm via `git rev-parse --show-toplevel` inside the opencode session).

(No git commit for the prompt file or the config — both are dotfiles outside the repo. The plan-doc and spec-doc updates that record this amendment ARE in-repo and should be committed together.)

---

## Done

When Tasks 1–8 pass, Task 9 passes or is skipped, and Task 10 (this amendment) is applied, the implementation is complete.

Final verification checklist:
- [ ] `envs/openrouter.env` committed in `igou-devenv` (Task 1).
- [ ] Two prompt files exist under `~/.config/opencode/prompts/` (Tasks 2–3).
- [ ] `~/.config/opencode/opencode.jsonc` updated, `opencode.jsonc.bak` exists (Task 4).
- [ ] `opencode --version` runs cleanly (Task 4 step 5).
- [ ] `op inject` resolves the new env file (Task 5).
- [ ] Plan mode routes to OpenRouter, build mode routes to local (Tasks 6–7).
- [ ] End-to-end superpowers loop runs with subagents on local Qwen3 (Task 8).
- [ ] (Optional) Parallel dispatch confirmed (Task 9).
- [ ] `plan` agent permissions narrowed to allow `docs/superpowers/**` writes and the git commands needed to commit them (Task 10 amendment).

No documentation update is needed — the spec at `docs/superpowers/specs/2026-05-07-opencode-orchestrator-subagents-design.md` already records the design and the `CLAUDE.md` doesn't describe per-user opencode config.
