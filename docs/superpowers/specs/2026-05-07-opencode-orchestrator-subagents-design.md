# Superpowers-driven orchestration in opencode: GPT-5.5 plans, local Qwen3 executes

**Date:** 2026-05-07
**Status:** Draft (pending user review)
**Repo:** `igou-devenv` (config lives in `~/.config/opencode/`, not in this repo's tree)

## Goal

Configure opencode so the user talks to a large model on OpenRouter (GPT-5.5) for high-level planning and orchestration, and that model dispatches concrete work via the Task tool to subagents running on the user's self-hosted Qwen3-35B-A3B endpoint. The whole loop is driven by the already-loaded `superpowers` opencode plugin: brainstorming → writing-plans → subagent-driven-development → parallel dispatch.

## Background

The user's existing global opencode config (`~/.config/opencode/opencode.jsonc`) already:

- Defines a `llama.cpp` provider pointing at `https://qwen3-35b-a3b-llmkube-system.apps.ocp.igou.systems/v1` (Qwen3-35B-A3B running on the user's OpenShift cluster — `tools: true`, `reasoning: true`, 65k context).
- Sets that local model as the default `model`.
- Loads `superpowers@v5.0.7` as a plugin.

Two things are missing for the orchestrator pattern:

1. An OpenRouter provider entry with a paid GPT-5.5 model and explicit reasoning-effort.
2. A custom `orchestrator` primary agent pinned to GPT-5.5 (with path-globbed edit/bash permissions for `docs/superpowers/**`), and per-agent model overrides on the built-in `general`/`explore` subagents pinning them to local Qwen3 — plus prompt augmentations that wire the superpowers skill loop into both roles.

The standalone `opencode-run` container (`bin/opencode-run`) already bind-mounts `~/.config/opencode` and accepts `-e <env>` for 1Password-resolved secrets, so global config edits cover both the VS Code devcontainer and the standalone container with no launcher changes.

## Design

### Architecture

```
┌───────────────────────────────────────────────────────────┐
│  orchestrator agent  (custom primary; user types here)    │
│    model:        openai/gpt-5.5  (OpenRouter, paid)       │
│    reasoning:    effort = medium                          │
│    small_model:  llama.cpp/qwen3.6-35b-a3b  (local, free) │
│    tools:        Read, Grep, Glob, Task, Skill, WebFetch, │
│                  Edit/Write (path-globbed), Bash (git)    │
│    permissions:  edit  → deny except docs/superpowers/**  │
│                  bash  → deny except git status/diff/log, │
│                          git add docs/superpowers/*,      │
│                          git commit*                      │
│    role:         brainstorm → write spec/plan → dispatch  │
└───────────────────────────────────────────────────────────┘
                       │ Task(subagent, prompt)
                       │   parallel for independent steps
                       ↓
       ┌────────────────────────────┐   ┌───────────────────────┐
       │  general subagent          │ … │  explore subagent     │
       │  model: Qwen3-35B (local)  │   │  model: Qwen3 (local) │
       │  tools: all                │   │  tools: read-only     │
       │  rails: TDD,               │   │  role: codebase grep  │
       │    verification-before-    │   │    / file lookup      │
       │    completion,             │   │                       │
       │    systematic-debugging    │   │                       │
       └────────────────────────────┘   └───────────────────────┘

  build mode (Tab to switch — unchanged)
    model: llama.cpp/qwen3.6-35b-a3b   (existing global default)
    use when:  direct hands-on work without orchestration

  plan mode (Tab to switch — opencode default, no override)
    model: llama.cpp/qwen3.6-35b-a3b   (global default)
    use when:  read-only exploration on the local model
    note:      opencode's built-in plan-mode system reminder is
               unmovable, so plan mode is intentionally NOT the
               orchestrator role — see Amendment 2 below.
```

End-to-end skill loop:

1. User types a task into the `orchestrator` agent. GPT-5.5 invokes `superpowers:brainstorming` → writes `docs/superpowers/specs/<date>-<topic>-design.md`.
2. After spec approval, GPT-5.5 invokes `superpowers:writing-plans` → writes the implementation plan.
3. GPT-5.5 invokes `subagent-driven-development` + `dispatching-parallel-agents` → emits parallel `Task` calls to `general` (and `explore` for lookups).
4. Each `general` invocation runs on local Qwen3 with TDD/verification rails baked into its system prompt. Returns evidence-bearing report.
5. GPT-5.5 reviews subagent output, dispatches the next wave or reports back to the user.

The reason this works with a smaller executor model: superpowers' rigid skills (TDD, verification-before-completion, systematic-debugging) are procedural rails. A 35B model following an explicit procedure performs noticeably better than the same model improvising — and the rails come for free because the plugin is already loaded.

### Config schema — additions to `~/.config/opencode/opencode.jsonc`

Diff against the current file. The existing `llama.cpp` provider entry is preserved verbatim.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",

  "provider": {
    "llama.cpp": { /* unchanged */ },

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

  "model":       "llama.cpp/qwen3.6-35b-a3b",   // build-mode default, unchanged
  "small_model": "llama.cpp/qwen3.6-35b-a3b",   // NEW — title gen on local

  "agent": {
    "orchestrator": {
      "description": "Superpowers-driven planner. Brainstorms, writes spec/plan, dispatches subagents via Task. Runs on GPT-5.5 (paid OpenRouter).",
      "mode": "primary",
      "model": "openrouter/openai/gpt-5.5",
      "prompt": "{file:./prompts/orchestrator.md}",
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
    },
    "general": {
      "mode": "subagent",
      "model": "llama.cpp/qwen3.6-35b-a3b",
      "prompt": "{file:./prompts/general-executor.md}"
    },
    "explore": {
      "mode": "subagent",
      "model": "llama.cpp/qwen3.6-35b-a3b"
      // keep built-in prompt — explore is already well-scoped
    }
  },

  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git#v5.0.7"]
}
```

Notes on field choices:

- `options.reasoning.effort` (nested) is the OpenRouter form. Native-OpenAI provider uses `reasoningEffort` (flat); this design uses OpenRouter, so the nested form applies.
- `effort: "medium"` chosen for balanced cost/latency on the orchestrator. Easy to bump to `high` later.
- The orchestrator role is a **custom primary agent**, not an override of the built-in `plan` mode. Smoke testing (Amendment 2 below) showed opencode's built-in plan mode injects an unmovable system reminder forbidding edits, regardless of the agent-level permission rules — the model treats it as inviolable and refuses to attempt writes even when the rules would allow them. A custom primary inherits no such reminder and lets path-globbed permissions actually bind. The `general` and `explore` overrides remain merge-style on the built-in subagents because subagents have no equivalent built-in restriction.
- The `orchestrator` agent's permissions are path-globbed rather than blanket-deny. `edit` covers all file mutation (`edit`, `write`, `patch` per opencode's permission semantics) and is denied except for paths under `docs/superpowers/specs/**` and `docs/superpowers/plans/**` — the artifacts the orchestrator authors itself via `superpowers:brainstorming` and `superpowers:writing-plans`. `bash` is denied except for read-only git inspection (`git status*`, `git diff*`, `git log*`) and the two write commands needed to commit those artifacts (`git add docs/superpowers/*`, `git commit*`). Without these narrow allows, the orchestrator cannot write its own spec/plan files and would have to delegate that to a subagent — a round-trip that risks transcription fidelity loss when GPT-5.5 prose passes through Qwen3-35B. The blanket `edit`/`bash` denies would also conflict directly with the brainstorming and writing-plans skills, which mandate that the agent running them writes the spec/plan files.
- `{file:./prompts/...}` references are resolved relative to the config file, so they live in `~/.config/opencode/prompts/`.

### Prompt augmentations

Two new files alongside the config.

**`~/.config/opencode/prompts/orchestrator.md`** — system prompt for the custom orchestrator agent:

```markdown
You are the `orchestrator` primary agent in opencode — a superpowers-aware planner that runs on GPT-5.5.

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
```

**`~/.config/opencode/prompts/general-executor.md`** — augments the `general` subagent:

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

The `explore` subagent is left with its built-in prompt — it's already constrained to read-only codebase lookup, and adding superpowers verbiage there would only bloat its context.

### Auth — new `envs/openrouter.env` in this repo

```bash
# envs/openrouter.env
OPENROUTER_API_KEY=op://claude/openrouter-paid/token
```

The 1Password item path `op://claude/openrouter-paid/token` is a placeholder — the user creates a paid OpenRouter key and stores it under that vault entry before first use. The existing `envs/openrouter-free.env` stays as-is; it serves a different purpose (Claude-Code-via-OpenRouter shim) and uses different env vars (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`).

Usage paths:

- **In the devcontainer (VS Code/Cursor):** `use openrouter` in the shell (the existing 1Password env-injection function from ADR-0001), then run `opencode`. GPT-5.5 picks up the key only when the user switches to the `orchestrator` agent.
- **Standalone:** `opencode-run -e openrouter`. The launcher already wires `-e`.
- **`build` mode never touches OpenRouter.** No key is required for solo Qwen3 work; the provider's `apiKey: "{env:OPENROUTER_API_KEY}"` only resolves when an OpenRouter call is actually made.

### What is *not* changing

| Area | Reason |
|---|---|
| `bin/opencode-run` | `-e openrouter` already works; no launcher changes needed. |
| `.devcontainer/devcontainer.json` | `~/.config/opencode` already bind-mounted; no new mounts. |
| `.devcontainer/Dockerfile` | opencode binary already installed; superpowers loaded at runtime via the `plugin` array. |
| `dotfiles/.bashrc` | The `use`/`unuse` env-injection functions already exist. |
| `build` mode | Stays on local Qwen3; current behavior preserved as the default. |
| The standalone `opencode` container (`igou-containers/apps/opencode`) | Same `~/.config/opencode` mount path; gets the same config for free. |
| `tests/test-tools.sh` | This is config-and-prompts, not a CLI tool surface. |
| `renovate.json` | OpenRouter model strings have no version-pin convention; superpowers plugin is already pinned via the existing `plugin` array entry. |

## Verification

Manual smoke test, ordered. There is no automated test for this — it's config and prompts, validated by use.

1. Create the paid OpenRouter key in 1Password under `op://claude/openrouter-paid/token`.
2. `use openrouter` in the devcontainer shell; confirm `echo $OPENROUTER_API_KEY` resolves to a non-empty value.
3. Launch `opencode` → Tab (or `/agent orchestrator`) to switch to the `orchestrator` agent → ask a trivial question. Confirm in opencode's session log that the request routed to OpenRouter (`openai/gpt-5.5`) and returned.
4. Tab to `build` mode → ask the same trivial question. Confirm it routed to `llama.cpp/qwen3.6-35b-a3b`.
5. In the `orchestrator` agent, ask: *"Add a test to `tests/test-tools.sh` that verifies `jq` is on PATH."* Confirm:
    - GPT-5.5 announces invoking `superpowers:brainstorming` or `superpowers:writing-plans`.
    - The orchestrator writes the spec/plan files itself (under `docs/superpowers/specs/` and `docs/superpowers/plans/`) without prompting you to switch modes.
    - At least one `Task` call lands on `general` and runs against the local Qwen3 endpoint.
    - The subagent's report contains actual command output (e.g. the result of grepping the test file), not a paraphrased summary.
6. Optional: ask the `orchestrator` to do something with two independent steps (e.g. *"add a test for `jq` and a test for `yq`"*) and confirm the Task calls go out in parallel rather than sequentially.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `apiKey: "{env:OPENROUTER_API_KEY}"` fails silently if the env var is unset | First call into the `orchestrator` agent fails loudly with an auth error; user runs `use openrouter` and retries. Documented in the verification steps. |
| Qwen3 endpoint is single-replica, so parallel dispatch serializes anyway | Acceptable — parallel dispatch becomes a no-op rather than an error. Revisit by scaling the OCP `llmkube-system` deployment if it becomes a bottleneck. |
| Subagent prompt augmentation conflicts with built-in opencode subagent prompts (merge vs replace semantics) | If conflicts surface, switch to writing markdown agents under `~/.config/opencode/agents/general.md`, which fully replaces the built-in prompt rather than augmenting it. |
| Plugin propagation to subagents is not as assumed (subagents lack the `Skill` tool at runtime) | Fall back: bake the relevant skill *content* directly into the subagent prompt rather than relying on `Skill`-tool invocation. The procedural rails are what matter; the tool is just the delivery mechanism. |
| GPT-5.5 model ID drift on OpenRouter | Single-string change in `opencode.jsonc`; not a meaningful risk. |
| Reasoning-effort field name varies between native OpenAI (`reasoningEffort`) and OpenRouter (`reasoning.effort`) | Spec uses the OpenRouter form to match the routing path. If the user ever adds a native-OpenAI provider entry, it will need the flat field. |

## Out of scope

- Wiring `opencode-run` to auto-inject `openrouter.env` (deliberate — keeps the cost surface explicit; the user opts in per session).
- Adding custom subagents beyond the built-in `general`/`explore` (later iteration if patterns emerge).
- A Renovate datasource for the GPT-5.5 model string (no version-pinning convention for OpenRouter model names).
- Replacing or restructuring the existing `llama.cpp` provider entry — it is already correct.
- Adding the orchestrator pattern to the runtime container launched by `claude-run` — that container is built from `igou-containers` and runs the Anthropic Claude Code CLI, not opencode.

## Amendments

Both amendments were applied during initial smoke testing. The body of this spec already reflects the final state; this section preserves the reasoning trail.

### Amendment 1 — narrow `plan` permissions to allow superpowers artifacts (superseded by Amendment 2)

The original draft specified blanket `edit`/`write`/`bash: deny` on the `plan` agent override. Smoke testing surfaced that `superpowers:brainstorming` and `superpowers:writing-plans` both require the agent running them to write spec/plan files — forcing a Tab to `build` mode mid-session and losing the orchestrator's GPT-5.5 context at exactly the wrong moments.

The first attempted fix narrowed the `plan` agent's permissions with path globs: `edit` allowed only under `docs/superpowers/{specs,plans}/**`, `bash` allowed only for read-only git inspection plus `git add docs/superpowers/*` and `git commit*`. The opencode permission ruleset accepted the new structure (verified in session logs), and bash decisions evaluated correctly.

This approach failed at the LLM layer. opencode's built-in plan mode injects an unmovable system reminder telling the model "you cannot edit." When asked to test write permissions explicitly, GPT-5.5 refused to attempt any edit, citing the higher-priority built-in instruction. The permission rules were never reached because the model never tried.

**Outcome:** plan mode is structurally inappropriate for the orchestrator role. Amendment 2 supersedes this approach.

### Amendment 2 — replace plan-mode override with a custom `orchestrator` primary agent

Removed the `agent.plan` override entirely (plan mode reverts to opencode default — read-only with the global `model: llama.cpp/qwen3.6-35b-a3b`, useful for local-model exploration but not for orchestration). Added a new custom primary agent `orchestrator` with `mode: primary`, the GPT-5.5 model, the same path-globbed `edit`/`bash` permissions from Amendment 1, and a renamed prompt file at `~/.config/opencode/prompts/orchestrator.md`.

Custom primary agents do not inherit plan-mode's hardcoded read-only system reminder, so the agent-level permission rules become the binding constraint. The user accesses the orchestrator via Tab cycling or `/agent orchestrator`. Build mode and the two subagents are unchanged.

**Smoke test for the architectural switch:** ask the orchestrator agent to write a small test file under `docs/superpowers/specs/`. If the model attempts the write and opencode permits it, the architecture is correct. If the model still refuses (or opencode denies despite our allow rule), the issue is deeper than agent typing and the design needs another revision.
