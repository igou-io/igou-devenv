# Permission levels

Per-driver tool-permission fragments selected by a `PERMISSIONS=<level>` line in
an `envs/*.env` profile and applied by `agent-sandbox-launch` (adr/0006):

| level      | intent                                                                 |
|------------|------------------------------------------------------------------------|
| `readonly` | no file edits; read-only shell and `oc`/`kubectl` get/describe/logs pre-approved; cluster-mutating commands denied |
| `guarded`  | edits allowed; cluster/fleet-mutating commands (`oc apply`, `argocd app sync`, `ansible-navigator run`, …) ask first |

| file            | consumed as                                                             |
|-----------------|-------------------------------------------------------------------------|
| `claude.json`   | merged over `~/.claude/settings.json` into the per-scope Claude home     |
| `codex.toml`    | appended to the per-scope `CODEX_HOME/config.toml`                       |
| `opencode.json` | merged into `OPENCODE_CONFIG_CONTENT`                                    |

The credential's RBAC is the hard boundary; these are the soft one (clear
errors instead of a 403 hunt, and an approval prompt in t3 for mutations).
