DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.DEFAULT_GOAL := help

.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env test-mise test-mise-lockfile test-qemu clean rebuild help renovate-validate renovate-dry-run sbom sbom-devcontainer e2e opencode-build mise-lock


## Build the devcontainer image (with cache)
## Runs: Dockerfile only (no lifecycle hooks)
build:
	$(DEVCONTAINER) build --workspace-folder $(WORKSPACE)

## Build (cached) and start the devcontainer
## Runs: init.sh → Dockerfile → onCreateCommand (pip) → post-create.sh → post-start.sh
## On subsequent starts (container already exists): post-start.sh only
up:
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) $(SSH_MOUNT)

## Restart the devcontainer (recreate without rebuilding image)
## Runs: init.sh → onCreateCommand (pip) → post-create.sh → post-start.sh
## Reuses cached image — Dockerfile does NOT rerun
restart: down up

## Rebuild from scratch (no cache, removes existing container)
## Runs: init.sh → Dockerfile (no cache) → onCreateCommand (pip) → post-create.sh → post-start.sh
rebuild:
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) \
		--remove-existing-container \
		--build-no-cache \
		$(SSH_MOUNT)

## Stop and remove the devcontainer
down:
	@CONTAINER=$$(docker ps -aq --filter "label=devcontainer.local_folder=$(WORKSPACE)"); \
	if [ -n "$$CONTAINER" ]; then \
		docker rm -f $$CONTAINER; \
		echo "Container removed."; \
	else \
		echo "No container found for this workspace."; \
	fi

## Open a shell in the running devcontainer
shell:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash

## Run a command in the running devcontainer (usage: make exec CMD="kubectl version")
exec:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) $(CMD)

## Run all tests (tools, podman, env, mise lockfile freshness + audit)
test-all: test-tools test-podman test-env test-mise-lockfile test-mise test-qemu

## Alias for test-all
test: test-all

## Verify CLI tools, Python packages, and user config inside the devcontainer
test-tools:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-tools.sh

## Test podman pull, run, and build inside the devcontainer
test-podman:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-podman.sh

## Test environment switching shell functions (use, k8s-unset, prompt)
test-env:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash -i /workspace/igou-devenv/tests/test-env.sh

## Audit mise-managed tools: each tool resolves to its expected verification method.
## Runs inside the devcontainer (needs mise + installed tools).
test-mise:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash /workspace/igou-devenv/tests/test-mise.sh

## Verify QEMU userspace and libvirt stack
test-qemu:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-qemu.sh

## Verify mise.lock is in sync with mise.toml. Runs on the host (uses
## host mise if available, otherwise a one-shot ghcr.io/jdx/mise container).
test-mise-lockfile:
	bash $(CURDIR)/tests/test-mise-lockfile.sh

## Regenerate mise.lock against the current mise.toml; commit both together.
## Run this after editing mise.toml — including on a Renovate mise PR, whose
## stale lock the mise-lockfile-check CI guard flags. Hosted Renovate (the Mend
## app) cannot run postUpgradeTasks, so it never regenerates the lockfile itself.
##
## Uses a one-shot ghcr.io/jdx/mise container so this works on any host
## with podman (the host does not need mise installed). Mise only writes
## to mise.lock if the file already exists; we touch it before invoking.
## Stash the previous lockfile so a transient failure (e.g. GitHub API
## rate limit, network blip) doesn't wipe the committed mise.lock.
mise-lock:
	@if ! command -v podman >/dev/null 2>&1; then \
		echo "podman not on PATH. Install podman or run mise locally."; \
		exit 1; \
	fi
	@[ -f mise.lock ] && cp mise.lock mise.lock.bak || touch mise.lock
	@if podman run --rm --entrypoint sh \
		-v "$(CURDIR):/work" \
		-v "$(CURDIR)/aqua-registry:/etc/mise/aqua-registry:ro" \
		-w /work \
		-e MISE_GLOBAL_CONFIG_FILE=/work/mise.toml \
		-e MISE_TRUSTED_CONFIG_PATHS=/work \
		-e MISE_LOCKED=0 \
		-e GITHUB_TOKEN \
		ghcr.io/jdx/mise:latest -c '\
			rm -f /mise/config.toml; \
			mise trust --quiet --all >/dev/null 2>&1 || true; \
			mise install --yes \
		' && [ -s mise.lock ]; then \
		rm -f mise.lock.bak; \
		echo "mise.lock regenerated. Commit both mise.toml and mise.lock together."; \
	else \
		echo "mise install failed or produced empty mise.lock; restoring previous mise.lock"; \
		[ -f mise.lock.bak ] && mv mise.lock.bak mise.lock; \
		exit 1; \
	fi

## Remove the devcontainer and clean up dangling images
clean: down
	@docker image prune -f 2>/dev/null || true

## Validate renovate.json config in this repo
renovate-validate:
	$(CURDIR)/bin/renovate-validate $(CURDIR)

## Dry-run Renovate against this repo (GITHUB_TOKEN required)
renovate-dry-run:
	$(CURDIR)/bin/renovate-dry-run $(CURDIR)

## End-to-end: rebuild devcontainer and run all devcontainer tests.
## Full validation from scratch.
e2e: rebuild test-all
	@echo "=== E2E complete ==="

## Generate SBOMs for the devcontainer image (SPDX + CycloneDX)
sbom: sbom-devcontainer

## Generate SBOM for the devcontainer image
sbom-devcontainer:
	@mkdir -p sbom
	@DEVCONTAINER_IMAGE=$$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^vsc-igou-devenv' | grep -v '\-uid' | head -1); \
	if [ -z "$$DEVCONTAINER_IMAGE" ]; then echo "No devcontainer image found. Run 'make build' first."; exit 1; fi; \
	echo "Generating SBOM for $$DEVCONTAINER_IMAGE..."; \
	syft "$$DEVCONTAINER_IMAGE" -o spdx-json=sbom/devcontainer.spdx.json -o cyclonedx-json=sbom/devcontainer.cdx.json; \
	echo "SBOMs written to sbom/devcontainer.{spdx,cdx}.json"

## Build the opencode container from igou-containers/apps/opencode/
## Tags as ghcr.io/igou-io/opencode:latest so opencode-run picks it up by default
opencode-build:
	@OPENCODE_DIR=$(CURDIR)/../igou-containers/apps/opencode; \
	if [ ! -d "$$OPENCODE_DIR" ]; then \
		echo "opencode build context not found at $$OPENCODE_DIR"; \
		echo "expected igou-containers checked out next to igou-devenv"; \
		exit 1; \
	fi; \
	podman build -t ghcr.io/igou-io/opencode:latest -f $$OPENCODE_DIR/Containerfile $$OPENCODE_DIR

help: ## Show available targets
	@awk '/^## /{if(!desc) desc=substr($$0,4); next} /^[a-zA-Z_-]+:/{if(desc){split($$1,a,":"); printf "  \033[36m%-25s\033[0m %s\n", a[1], desc} desc=""} !/^##/ && !/^[a-zA-Z_-]+:/{desc=""}' $(MAKEFILE_LIST)
