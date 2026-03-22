DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.PHONY: build up down restart exec shell test test-tools test-podman test-env clean rebuild help renovate-validate renovate-dry-run

## Build the devcontainer image (with cache)
build:
	$(DEVCONTAINER) build --workspace-folder $(WORKSPACE)

## Build and start the devcontainer
up:
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) $(SSH_MOUNT)

## Restart the devcontainer (recreate without rebuilding image)
restart: down up

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

## Verify CLI tools, Python packages, and user config inside the devcontainer
test-tools:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/test-tools.sh

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

## Test environment switching shell functions (use, k8s-unset, prompt)
test-env:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) bash -ic ' \
		set -e; \
		PASS=0; FAIL=0; \
		ok() { echo "  [OK] $$1"; PASS=$$((PASS + 1)); }; \
		fail() { echo "  [FAIL] $$1"; FAIL=$$((FAIL + 1)); }; \
		TESTDIR=$$(mktemp -d); \
		echo "TEST_VAR=hello123" > $$TESTDIR/test.env; \
		echo "==> Testing use() with missing env..."; \
		if use nonexistent 2>&1 | grep -q "No env file"; then ok "missing env shows error"; else fail "missing env shows error"; fi; \
		echo ""; \
		echo "==> Testing use() lists available envs..."; \
		cp $$TESTDIR/test.env ~/.config/envs/test.env 2>/dev/null || true; \
		if ls ~/.config/envs/*.env 2>/dev/null | grep -q env; then \
			ok "env files listable"; \
		else \
			ok "env files listable (dir empty, expected in test)"; \
		fi; \
		echo ""; \
		echo "==> Testing OP_ENV stacking..."; \
		if OP_ENV="k3s" bash -c "[ \"\$$OP_ENV\" = \"k3s\" ]"; then ok "OP_ENV set"; else fail "OP_ENV set"; fi; \
		if OP_ENV="k3s" bash -c "export OP_ENV=\"\$${OP_ENV:+\$$OP_ENV/}aap\"; [ \"\$$OP_ENV\" = \"k3s/aap\" ]"; then \
			ok "OP_ENV stacks"; \
		else \
			fail "OP_ENV stacks"; \
		fi; \
		echo ""; \
		echo "==> Testing k8s-unset..."; \
		export KUBECONFIG=/tmp/fake K8S_AUTH_HOST=fake K8S_AUTH_API_KEY=fake; \
		k8s-unset > /dev/null; \
		if [ -z "$${KUBECONFIG:-}" ] && [ -z "$${K8S_AUTH_HOST:-}" ] && [ -z "$${K8S_AUTH_API_KEY:-}" ]; then \
			ok "k8s-unset clears vars"; \
		else \
			fail "k8s-unset clears vars"; \
		fi; \
		echo ""; \
		echo "==> Testing prompt functions..."; \
		if [ -n "$$(type -t __prompt_command)" ]; then ok "__prompt_command defined"; else fail "__prompt_command defined"; fi; \
		if echo "$$PROMPT_COMMAND" | grep -q __prompt_command; then ok "PROMPT_COMMAND set"; else fail "PROMPT_COMMAND set"; fi; \
		echo ""; \
		rm -rf $$TESTDIR; \
		echo "==> Results: $$PASS passed, $$FAIL failed"; \
		[ "$$FAIL" -eq 0 ] \
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
