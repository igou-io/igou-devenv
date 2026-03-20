DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.PHONY: build up down exec shell test test-podman clean rebuild help renovate-validate renovate-dry-run

## Build the devcontainer image (with cache)
build:
	$(DEVCONTAINER) build --workspace-folder $(WORKSPACE)

## Build and start the devcontainer
up:
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) $(SSH_MOUNT)

## Rebuild from scratch (no cache, removes existing container)
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

## Build the Dockerfile and check apt-installed tools
test:
	./test.sh

## Test podman pull, run, and build inside the devcontainer
test-podman:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash -c ' \
		set -e; \
		echo "==> podman pull..."; \
		podman pull docker.io/library/alpine:latest; \
		echo "==> podman run..."; \
		podman run --rm docker.io/library/alpine:latest echo "hello from podman"; \
		echo "==> podman build..."; \
		TMP=$$(mktemp -d); \
		echo "FROM docker.io/library/alpine:latest" > $$TMP/Containerfile; \
		podman build -t podman-test:local $$TMP; \
		podman rmi -f podman-test:local docker.io/library/alpine:latest; \
		rm -rf $$TMP; \
		echo "==> All podman tests passed" \
	'

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

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
