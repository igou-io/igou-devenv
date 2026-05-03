DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.DEFAULT_GOAL := help

.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env clean rebuild help renovate-validate renovate-dry-run sbom sbom-devcontainer e2e opencode-build


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

## Run all tests (tools, podman, env)
test-all: test-tools test-podman test-env

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
