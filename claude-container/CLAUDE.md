# Global CLAUDE.md — Claude Container

This file applies to all Claude Code sessions launched via `claude-run` inside the container. Project-specific CLAUDE.md files in each workspace repo take precedence for repo-specific guidance.

## Environment

You are running inside a hardened UBI10-based container launched via `claude-run`. Key constraints:

- **No package managers**: pip, dnf, rpm, and ansible-galaxy have been removed. All tools are baked into the image.
- **No internet access** except: api.anthropic.com, claude.ai, statsig.anthropic.com, sentry.io, github.com
- **/tmp is noexec**: You cannot download and execute binaries. Use only the tools already installed.
- **~/.local/bin is read-only**: You cannot modify PATH or install new CLI tools.
- **Container is ephemeral**: Changes outside /workspace and ~/.claude are lost on exit.

## Available Tools

### CLI tools
kubectl, helm, kustomize, argocd, oc, virtctl, kubeconform, tkn, gh, ansible, ansible-runner, ansible-lint, yamllint, jq, yq, python3, git, make, nmap, socat, curl, rclone, mc, kubernetes-mcp-server

### MCP servers
- **kubernetes**: Use `mcp__kubernetes__*` tools for cluster inspection. Prefer MCP over `oc`/`kubectl` CLI when possible — it provides structured output without shell overhead.

### Credentials
Cluster credentials and API keys are injected via environment variables at launch (resolved from 1Password via `op inject`). Check `$KUBECONFIG` and `$GITHUB_TOKEN` for what's available in this session.

### Git push/pull
The container does not have SSH keys. Use `gh` CLI for all git remote operations — it authenticates via `$GITHUB_TOKEN` set by the entrypoint:

```bash
gh repo clone igou-io/<repo>       # clone
gh pr create                        # create PR
git push                            # works — entrypoint configures git credential helper with GITHUB_TOKEN
git pull                            # works — same credential helper
```

If `git push` fails with auth errors, verify `$GITHUB_TOKEN` is set. The entrypoint runs `gh auth login --with-token` and configures `git credential.helper store` automatically when the token is present.

## Working with infrastructure repos

### General conventions
- YAML files: 2-space indentation, start with `---`
- Use YAML 1.2 booleans (`true`/`false`, not `yes`/`no`)
- Secrets are never stored in git — use External Secrets Operator or 1Password references
- Container images should be pinned to digest where possible
- Validate before committing: `make test` or `make lint` in repos that have a Makefile

### Kubernetes / OpenShift repos (igou-kubernetes, igou-openshift, rosa-gitops)
- Kustomize-based GitOps managed by ArgoCD
- Validate with: `kustomize build <path>`, `kubeconform`, `yamllint`
- ArgoCD app-of-apps pattern with sync-wave ordering
- Check cluster-specific config under `clusters/<name>/` — do not assume one cluster's network layout applies to another

### Ansible repos (igou-ansible, igou-inventory)
- Playbooks executed via ansible-navigator with containerized execution environments
- Inventory lives in igou-inventory (separate repo, symlinked)
- Lint with: `ansible-lint --profile=production`
- Roles: mix of community (pinned in requirements.yml) and custom (in roles/)
- Molecule testing available for some scenarios

### Terraform repos (igou-infrastructure)
- Standard terraform layout: main.tf, variables.tf, outputs.tf, data.tf
- Never run `terraform apply` without explicit user confirmation
- Use `terraform plan` to preview changes

## Research guidelines

When researching OpenShift APIs and features, fetch raw AsciiDoc from the openshift-docs repo:
```
https://raw.githubusercontent.com/openshift/openshift-docs/enterprise-4.21/<path>.adoc
```
Do not use docs.okd.io or docs.redhat.com — both are JS-rendered and return only navigation, not content. Assembly files use `include::modules/<name>.adoc` — fetch the module file directly for actual content.

Always verify API group/version/kind against the live cluster using `oc api-resources` or `oc explain` before recommending usage. Check whether features are Tech Preview vs GA.
