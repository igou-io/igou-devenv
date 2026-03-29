DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env clean rebuild help renovate-validate renovate-dry-run claude-build claude-rebuild claude-test claude-test-run claude-test-all e2e sbom sbom-devcontainer sbom-claude


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

## Validate renovate.json config
renovate-validate:
	docker run --rm -v $(CURDIR):/repo:ro -w /repo renovate/renovate renovate-config-validator

## Dry-run Renovate against the local repo to see what it would update (GITHUB_TOKEN required for github-releases datasource)
renovate-dry-run:
	@if [ -z "$$GITHUB_TOKEN" ]; then echo "GITHUB_TOKEN required for github-releases datasource lookups"; exit 1; fi
	docker run --rm \
		-v $(CURDIR):/repo \
		-w /repo \
		-e GITHUB_COM_TOKEN=$$GITHUB_TOKEN \
		-e RENOVATE_DRY_RUN=lookup \
		-e LOG_LEVEL=debug \
		renovate/renovate \
		--platform=local

## Build the Claude container image (with cache)
claude-build:
	podman build -t claude-devenv -f claude-container/Containerfile claude-container/

## Rebuild the Claude container image from scratch (no cache)
claude-rebuild:
	podman build --no-cache -t claude-devenv -f claude-container/Containerfile claude-container/

## Run tool verification tests inside the Claude container
claude-test:
	podman run --rm -v $(CURDIR)/claude-container/test.sh:/tmp/test.sh:ro,Z claude-devenv bash /tmp/test.sh

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
		-v $(CURDIR)/claude-container/test-hardened.sh:/workspace/test-hardened.sh:ro,Z \
		claude-devenv bash /workspace/test-hardened.sh

## Test claude-run secret resolution and argument assembly (uses mock op/podman)
claude-test-run:
	$(CURDIR)/claude-container/test-claude-run.sh

## Run all Claude container tests (tools, hardened, claude-run)
claude-test-all: claude-test claude-test-hardened claude-test-run

## End-to-end: rebuild devcontainer, run devcontainer tests, build Claude container
## inside devcontainer, run Claude container tests. Full validation from scratch.
e2e:
	@echo "=== Phase 1: Rebuild devcontainer ==="
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) \
		--remove-existing-container \
		--build-no-cache \
		$(SSH_MOUNT)
	@echo ""
	@echo "=== Phase 2: Devcontainer tests ==="
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-tools.sh
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-podman.sh
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash -i /workspace/igou-devenv/tests/test-env.sh
	@echo ""
	@echo "=== Phase 3: Build Claude container inside devcontainer ==="
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) \
		podman build --no-cache -t claude-devenv -f /workspace/igou-devenv/claude-container/Containerfile /workspace/igou-devenv/claude-container/
	@echo ""
	@echo "=== Phase 4: Claude container tests (inside devcontainer) ==="
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) \
		podman run --rm -v /workspace/igou-devenv/claude-container/test.sh:/tmp/test.sh:ro,Z claude-devenv bash /tmp/test.sh
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) \
		/workspace/igou-devenv/claude-container/test-claude-run.sh
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) \
		podman run --rm \
			--init \
			--cap-drop=ALL \
			--security-opt no-new-privileges:true \
			--tmpfs /tmp:rw,noexec,nosuid,size=256m \
			--tmpfs /run:rw,noexec,nosuid,size=64m \
			--pids-limit=512 \
			--ulimit nofile=1024:2048 \
			--ulimit nproc=512:512 \
			--ulimit core=0 \
			-v /workspace/igou-devenv/claude-container/test-hardened.sh:/workspace/test-hardened.sh:ro,Z \
			claude-devenv bash /workspace/test-hardened.sh
	@echo ""
	@echo "=== E2E complete ==="

## Generate SBOMs for all container images (SPDX + CycloneDX)
sbom: sbom-devcontainer sbom-claude

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

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
