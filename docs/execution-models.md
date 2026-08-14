# Execution Models

This repository has several valid ways to run tooling, and they do not share
the same security model or kernel/runtime capabilities. Treat each model as a
separate environment until tested.

## Runtime Matrix

| Model | Entry point | Container/runtime | Privilege assumptions | Available container engine? | Credential handling | AI CLIs involved | Sandbox expectations | Where dependencies are maintained |
|---|---|---|---|---|---|---|---|---|
| Local full devcontainer | Cursor Dev Containers, devcontainer CLI, or `make up` | Docker starts `.devcontainer/devcontainer.json` | Trusted local workstation; Docker `--privileged`; host networking; `/dev`, `/dev/fuse`, `/dev/net/tun`, Docker socket, host workspace, SSH, kube, Claude, Codex, OpenCode, Cursor, and 1Password config mounts | Yes. Podman/buildah/skopeo inside the container; Docker CLI through host socket | Host config/state bind mounts; `op` can resolve env files directly in the devcontainer | `claude`, `codex`, `cursor-agent`/`agent`, `opencode`; wrapper scripts may launch separate agent containers | Not a security sandbox. Tool-specific native sandboxing may be available only if the tool supports it and runtime smoke tests pass | Main image packages in `.devcontainer/Dockerfile`; mise tools in `mise.toml`/`mise.lock`; Python in `.devcontainer/requirements.txt` |
| Lightweight `make run` / published image path | `make run` | `docker run` of `ghcr.io/igou-io/igou-devenv:<tag>` | Lightweight code-server path against one selected directory; no devcontainer lifecycle hooks; no assumption of privileged mode or full persistence | Do not assume nested Podman/buildah or Docker socket unless explicitly wired | Mounts selected directory; password passed/generated for code-server; normal full-devcontainer credential mounts are not implied | CLIs baked into the image may exist, but this path is primarily for code-server | Do not inherit full-devcontainer capability claims; test any needed sandbox primitive inside this container | Same published image contents as this repo builds, but runtime flags come from `make run` |
| Local wrapper-launched agent containers | `bin/claude-run`, `bin/cursor-run`, `bin/opencode-run` | Rootless Podman containers launched by wrapper scripts, normally from inside the full devcontainer | Wrapper hardening flags apply; not privileged; no nested containers by design | The launching environment needs working rootless Podman; the agent containers themselves do not provide a container engine | Wrappers run `op inject` in the devcontainer, then pass resolved plain environment variables to the agent container. Agent container does not get direct 1Password access | Claude Code image, Cursor agent image, OpenCode image from `ghcr.io/igou-io/*` | Tool-specific. Claude/Codex-style sandboxes require their own packages and working runtime primitives; OpenCode permissions are not OS isolation | Agent images are built in `igou-containers`. Wrapper scripts live here but should not grow image package logic |
| Hermes docker-terminal container | Hermes docker terminal setting | Hermes rootless Podman environment enters the configured image | Do not assume privileged mode, host network, host Docker socket, `/dev` bind, or nested Podman | Must be tested. Do not assume Docker or Podman is available inside the Hermes-entered image | Depends on Hermes configuration and the entered image. Do not assume direct 1Password access or local wrapper secret flow | Whatever AI CLI exists in the image Hermes enters | The outer container is the primary isolation boundary. Tool-specific native sandboxing exists only if the tool, packages, and runtime support it | Patch the image Hermes actually enters. This may or may not be `igou-devenv` |
| OpenShift Dev Spaces workspace | Factory URL on devspaces.apps.ocp.igou.systems (`devfile.yaml`) | DevWorkspace pod on the ocp cluster runs the published image; Dev Spaces injects che-code | Arbitrary UID in root group under the `container-build` SCC (SETUID/SETGID only). No `--privileged`, host network, Docker socket, or `/dev` passthrough; no devcontainer lifecycle hooks — `devspaces-bootstrap.sh` runs at postStart | Partial: image pulls + COPY-only builds + push work with the env recipe in igou-devenv#209; `RUN` steps and `podman run` are blocked by the container-build SCC (masked /proc, no DAC_OVERRIDE, setgroups-deny). No KVM/libvirt | `OP_CONNECT_HOST`/`OP_CONNECT_TOKEN` env from the auto-mounted per-user `op-connect` secret (igou-openshift devspaces-users chart); `oc` logged in as the Dev Spaces user; no host bind mounts — agent CLI auth starts fresh and persists on the per-user PVC | CLIs baked into the image (`claude`, `codex`, `agent`, `opencode`); wrapper-launched agent containers untested here | Not a security sandbox; tool-native sandboxes must be tested in this runtime | Same image as this repo builds; workspace shape in `devfile.yaml`, cluster wiring in igou-openshift `components/devspaces` |
| CI/build environment | GitHub Actions workflows, devcontainers CI | CI builds and tests the devcontainer image | CI should hard-fail on missing packages and broken commands. Do not assume kernel features for nested namespaces unless CI is configured for them | The image includes Podman/buildah for tests; host/container runtime support may vary by CI | CI secrets only where workflows provide them; normal user host mounts do not exist | Built CLIs should execute for version checks | Package availability is hard-tested. Namespace/bubblewrap runtime checks are diagnostic by default | This repo's Dockerfile, mise files, requirements, tests, and workflows |

## Capability Claims Checklist

Legend: Yes means expected for that model. No means do not claim it. Test means
possible only after a runtime check in that exact environment. Configured means
it depends on explicit wiring outside this repo's default path.

| Capability claim | Local full devcontainer | Lightweight `make run` | Local wrapper-launched agent containers | Hermes docker-terminal container | OpenShift Dev Spaces workspace | CI/build environment |
|---|---|---|---|---| --- |---|
| Can run nested Podman | Yes | No | No | Test | Partial: pull/COPY-build/push only — `RUN`/`podman run` blocked by SCC (igou-devenv#209) | Test |
| Has host Docker socket | Yes | No | No | No | No | No |
| Has `/dev` mounted from host | Yes | No | No | Test | No | No |
| Uses host networking | Yes | No | No | Test | No | No |
| Has direct 1Password CLI access | Yes | No | No, wrappers pass resolved env vars | Configured/Test | Yes, via Connect env from the mounted `op-connect` secret | No |
| Can use bubblewrap | Test | Test | Test in the launched image | Test | Test | Diagnostic by default |
| Can use Claude sandbox | Test with Claude in that runtime | Test | Test in Claude image | Test in Hermes-entered image | Test in this runtime | Diagnostic by default |
| Can use Cursor Landlock/seccomp | Test with Cursor agent in that runtime | Test | Test in Cursor image | Test in Hermes-entered image | Test in this runtime | Diagnostic by default |
| OpenCode isolated | Outer container only; OpenCode permissions are UX guardrails | Outer container only | Outer container only | Outer container only | Outer container only | Outer container only |
| Has 1Password direct access | Yes | No | No | Configured/Test | Yes, via Connect env | No |
| Can run `claude-run`, `cursor-run`, or `opencode-run` | Yes, intended path | No | Not applicable | No, unless explicitly wired and tested | No, unless explicitly wired and tested | No |
| Can claim OS sandboxing | Only for a specific tool after tests | Only after tests | Only for a specific tool/image after tests | Only for a specific tool/image after tests | Only for a specific tool after tests | No, unless CI is configured and tests require it |

## Hermes-Specific Rules

- Do not treat `claude-run`, `cursor-run`, or `opencode-run` as Hermes paths.
- Hermes runs in a rootless Podman environment and enters an image through the
  Hermes docker terminal setting.
- Do not assume the Hermes image is the same as the local full devcontainer
  unless Hermes is explicitly configured that way.
- Do not assume Hermes can run local wrapper scripts.
- Do not assume Hermes has privileged mode, host networking, the host Docker
  socket, `/dev` bind mounts, nested Podman, or local wrapper-launched agent
  containers.
- When adding dependencies for Hermes, patch the image Hermes actually enters, not merely local wrapper-launched agent images.
- Any dependency needed by agents launched inside Hermes must exist inside the image Hermes actually enters.
- Runtime capabilities such as user namespaces, mount namespaces, seccomp,
  Landlock, and bubblewrap must be tested inside the actual Hermes-entered
  container.
- The outer container is the primary isolation boundary for Hermes.

## Sandboxing Rules By Agent

Codex:

- Linux sandboxing expects bubblewrap or a compatible helper.
- `bubblewrap` must exist in the image where Codex runs.
- Do not claim Codex sandboxing works until the runtime smoke test passes inside
  that image.

Claude Code:

- Linux sandboxing expects bubblewrap and socat.
- `bubblewrap` and `socat` must exist in the image where Claude Code runs.
- Fail-closed behavior should only be claimed when configured and verified in
  that runtime.

Cursor agent:

- Linux sandboxing is Landlock/seccomp based when supported.
- Kernel and runtime support must be tested inside the container where the agent
  runs.
- Do not infer support from package installation alone.

OpenCode:

- OpenCode has no native OS sandbox in this model.
- OpenCode permissions are UX guardrails, not OS isolation.
- Use the outer container or VM as the isolation boundary.

Pi-style agents:

- Sandbox extensions commonly need bubblewrap, socat, and ripgrep.
- Install those dependencies in the image where the agent runs.
- Test inside the runtime before claiming they work.

## Do Not Overclaim

Never say "agent containers have bubblewrap + seccomp sandbox" generically.
Say "tool-specific native sandboxing may be available; verified by tests" only
after the relevant tool and runtime have passed smoke tests.

Do not claim a sandbox exists unless the relevant tool supports one and the runtime smoke test passes.
