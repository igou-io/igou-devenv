DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.DEFAULT_GOAL := help

.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env clean rebuild help renovate-validate renovate-dry-run base-build base-rebuild base-test claude-build claude-rebuild claude-test claude-test-hardened claude-test-run claude-test-all cursor-build cursor-rebuild cursor-test cursor-test-hardened cursor-test-run cursor-test-all e2e sbom sbom-devcontainer sbom-claude sbom-cursor


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

## Build the base agent image (with cache)
base-build:
	podman build -t agent-base -f containers/base/Containerfile containers/base/

## Rebuild the base agent image from scratch (no cache)
base-rebuild:
	podman build --no-cache -t agent-base -f containers/base/Containerfile containers/base/

## Run tool verification tests on the base agent image
base-test:
	podman run --rm -v $(CURDIR)/containers/base/test.sh:/tmp/test.sh:ro,Z agent-base bash /tmp/test.sh

## Build the Claude container image (with cache)
claude-build: base-build
	podman build -t claude-devenv -f containers/claude-code/Containerfile containers/claude-code/

## Rebuild the Claude container image from scratch (no cache)
claude-rebuild: base-rebuild
	podman build --no-cache -t claude-devenv -f containers/claude-code/Containerfile containers/claude-code/

## Run tool verification tests inside the Claude container
claude-test:
	podman run --rm -v $(CURDIR)/containers/claude-code/test.sh:/tmp/test.sh:ro,Z claude-devenv bash /tmp/test.sh

## Test Claude under full hardening (--cap-drop=ALL, noexec /tmp, resource limits)
claude-test-hardened:
	podman run --rm \
		--init \
		--cap-drop=ALL \
		--security-opt no-new-privileges:true \
		--tmpfs /tmp:rw,noexec,nosuid,size=256m \
		--tmpfs /run:rw,noexec,nosuid,size=64m \
		--cpus=2 \
		--memory=4g \
		--memory-swap=4g \
		--pids-limit=512 \
		--ulimit nofile=1024:2048 \
		--ulimit nproc=512:512 \
		--ulimit core=0 \
		-v $(CURDIR)/containers/claude-code/test-hardened.sh:/workspace/test-hardened.sh:ro,Z \
		claude-devenv bash /workspace/test-hardened.sh

## Test claude-run secret resolution and argument assembly (uses mock op/podman)
claude-test-run:
	$(CURDIR)/containers/claude-code/test-claude-run.sh

## Run all Claude container tests (tools, hardened, claude-run)
claude-test-all: claude-test claude-test-hardened claude-test-run

## Build the Cursor agent container image (with cache)
cursor-build: base-build
	podman build -t cursor-agent -f containers/cursor-agent-cli/Containerfile containers/cursor-agent-cli/

## Rebuild the Cursor agent container image from scratch (no cache)
cursor-rebuild: base-rebuild
	podman build --no-cache -t cursor-agent -f containers/cursor-agent-cli/Containerfile containers/cursor-agent-cli/

## Run tool verification tests inside the Cursor agent container
cursor-test:
	podman run --rm -v $(CURDIR)/containers/cursor-agent-cli/test.sh:/tmp/test.sh:ro,Z cursor-agent bash /tmp/test.sh

## Test Cursor agent under full hardening (--cap-drop=ALL, noexec /tmp, resource limits)
cursor-test-hardened:
	podman run --rm \
		--init \
		--cap-drop=ALL \
		--security-opt no-new-privileges:true \
		--tmpfs /tmp:rw,noexec,nosuid,size=256m \
		--tmpfs /run:rw,noexec,nosuid,size=64m \
		--cpus=2 \
		--memory=4g \
		--memory-swap=4g \
		--pids-limit=512 \
		--ulimit nofile=1024:2048 \
		--ulimit nproc=512:512 \
		--ulimit core=0 \
		-v $(CURDIR)/containers/cursor-agent-cli/test-hardened.sh:/workspace/test-hardened.sh:ro,Z \
		cursor-agent bash /workspace/test-hardened.sh

## Test cursor-run secret resolution and argument assembly (uses mock op/podman)
cursor-test-run:
	$(CURDIR)/containers/cursor-agent-cli/test-cursor-run.sh

## Run all Cursor agent container tests (tools, hardened, cursor-run)
cursor-test-all: cursor-test cursor-test-hardened cursor-test-run

## End-to-end: rebuild devcontainer, run all devcontainer and container tests.
## Full validation from scratch.
e2e: rebuild test-all claude-rebuild claude-test-all cursor-rebuild cursor-test-all
	@echo "=== E2E complete ==="

## Generate SBOMs for all container images (SPDX + CycloneDX)
sbom: sbom-devcontainer sbom-claude sbom-cursor

## Generate SBOM for the devcontainer image
sbom-devcontainer:
	@mkdir -p sbom
	@DEVCONTAINER_IMAGE=$$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^vsc-igou-devenv' | grep -v '\-uid' | head -1); \
	if [ -z "$$DEVCONTAINER_IMAGE" ]; then echo "No devcontainer image found. Run 'make build' first."; exit 1; fi; \
	echo "Generating SBOM for $$DEVCONTAINER_IMAGE..."; \
	syft "$$DEVCONTAINER_IMAGE" -o spdx-json=sbom/devcontainer.spdx.json -o cyclonedx-json=sbom/devcontainer.cdx.json; \
	echo "SBOMs written to sbom/devcontainer.{spdx,cdx}.json"

## Generate SBOM for the Claude container image
sbom-claude:
	@mkdir -p sbom
	@if ! podman image exists claude-devenv; then echo "No claude-devenv image found. Run 'make claude-build' first."; exit 1; fi
	syft podman:claude-devenv -o spdx-json=sbom/claude-devenv.spdx.json -o cyclonedx-json=sbom/claude-devenv.cdx.json
	@echo "SBOMs written to sbom/claude-devenv.{spdx,cdx}.json"

## Generate SBOM for the Cursor agent container image
sbom-cursor:
	@mkdir -p sbom
	@if ! podman image exists cursor-agent; then echo "No cursor-agent image found. Run 'make cursor-build' first."; exit 1; fi
	syft podman:cursor-agent -o spdx-json=sbom/cursor-agent.spdx.json -o cyclonedx-json=sbom/cursor-agent.cdx.json
	@echo "SBOMs written to sbom/cursor-agent.{spdx,cdx}.json"

help: ## Show available targets
	@awk '/^## /{if(!desc) desc=substr($$0,4); next} /^[a-zA-Z_-]+:/{if(desc){split($$1,a,":"); printf "  \033[36m%-25s\033[0m %s\n", a[1], desc} desc=""} !/^##/ && !/^[a-zA-Z_-]+:/{desc=""}' $(MAKEFILE_LIST)
