DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.PHONY: build up down restart exec shell test test-all test-tools test-podman test-env clean rebuild help renovate-validate renovate-dry-run claude-build claude-rebuild claude-test claude-test-run


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

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
