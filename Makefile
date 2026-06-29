DEVCONTAINER = devcontainer
WORKSPACE    = $(CURDIR)

# Resolve SSH agent mount at shell level: only mount if the socket file exists
SSH_MOUNT = $(shell [ -S "$$SSH_AUTH_SOCK" ] && echo '--mount type=bind,source=$(SSH_AUTH_SOCK),target=/tmp/ssh-agent.sock --remote-env SSH_AUTH_SOCK=/tmp/ssh-agent.sock')

.DEFAULT_GOAL := help

.PHONY: build up up-release down restart exec shell run test test-all test-tools test-sandbox-primitives test-podman test-env test-mise test-mise-lockfile test-qemu clean rebuild help renovate-validate renovate-dry-run sbom sbom-devcontainer e2e opencode-build mise-lock release release-dry-run release-prepare release-watch


## Build the devcontainer image (with cache)
## Runs: Dockerfile only (no lifecycle hooks)
build:
	$(DEVCONTAINER) build --workspace-folder $(WORKSPACE)

## Build (cached) and start the devcontainer
## Runs: init.sh → Dockerfile → onCreateCommand (pip) → post-create.sh → post-start.sh
## On subsequent starts (container already exists): post-start.sh only
##
## The host SSH agent socket path ($SSH_AUTH_SOCK, e.g. /tmp/ssh-XXXX/agent.PID)
## is ephemeral — regenerated each login session — but gets baked into the
## container's bind mount at create time. `devcontainer up` restarts an existing
## container via `docker start`, which re-validates that baked source path and
## fails if it has gone stale. So before starting, drop any existing container
## whose ssh-agent mount source no longer exists; `devcontainer up` then
## recreates it with the current socket. Same-session restarts skip this.
up:
	@for c in $$(docker ps -aq --filter "label=devcontainer.local_folder=$(WORKSPACE)"); do \
		src=$$(docker inspect "$$c" --format '{{range .Mounts}}{{if eq .Destination "/tmp/ssh-agent.sock"}}{{.Source}}{{end}}{{end}}' 2>/dev/null); \
		if [ -n "$$src" ] && [ ! -S "$$src" ]; then \
			echo "==> ssh-agent mount source $$src is stale; recreating container"; \
			docker rm -f "$$c" >/dev/null; \
		fi; \
	done
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

# ---------------------------------------------------------------------------
# Run via the published image — pull-and-run code-server, no build, no login.
# The GHCR image is public, so `docker` pulls it anonymously. Opens DIR (default
# the current directory) in a browser IDE on PORT over HTTPS (--cert generates a
# self-signed cert; browse https:// and accept the warning). Ctrl-C stops it (--rm).
#   make run                                  # current dir, :latest, port 8080
#   make run DIR=~/code TAG=2026.06.15-3 PORT=8443 PASSWORD=hunter2
# Runs as the image's `igou` user (uid 1000); on a single-user host (your uid is
# 1000) the mounted directory is writable. Ephemeral: code-server config
# and extensions are not persisted (use `make up` for the full, persistent
# devcontainer). PASSWORD is generated and printed if not supplied.
# ---------------------------------------------------------------------------
IMAGE    ?= ghcr.io/igou-io/igou-devenv
TAG      ?= latest
PORT     ?= 8080
DIR      ?= $(CURDIR)
PASSWORD ?=

## Pull and run code-server from the published image (no build; usage: make run [DIR=~/code] [TAG=2026.06.15-3] [PORT=8443])
run:
	@pw='$(PASSWORD)'; [ -n "$$pw" ] || pw="$$(head -c 18 /dev/urandom | base64)"; \
	echo ">>> code-server → https://localhost:$(PORT)   (self-signed; password: $$pw)"; \
	docker run --rm -it --name igou-devenv-run \
		--user igou -e HOME=/home/igou -e PASSWORD="$$pw" \
		-p $(PORT):8080 \
		-v "$(DIR):/workspace:Z" \
		$(IMAGE):$(TAG) \
		code-server --bind-addr 0.0.0.0:8080 /workspace --cert

## Start the FULL devcontainer from the published image instead of building it
## locally. Pulls $(IMAGE):$(TAG) and runs it with the same mounts + lifecycle
## hooks as `make up` (post-start re-syncs code-server). The canonical
## devcontainer.json is left untouched — CI's build.yaml and `make build` depend
## on its `build:` config — so this derives an image-based config on the fly and
## passes it via --override-config, recreating the container from the pulled image.
##   make up-release                    # newest tested image (:latest)
##   make up-release TAG=2026.06.15-4   # pin a specific immutable release
up-release:
	@command -v jq >/dev/null 2>&1 || { echo "jq is required for up-release"; exit 1; }
	@echo "==> Pulling $(IMAGE):$(TAG)..."
	@docker pull $(IMAGE):$(TAG)
	@cfg="$$(mktemp -d)/devcontainer.json"; \
	jq 'del(.build) | .image = "$(IMAGE):$(TAG)"' .devcontainer/devcontainer.json > "$$cfg"; \
	echo "==> Starting devcontainer from $(IMAGE):$(TAG)"; \
	$(DEVCONTAINER) up --workspace-folder $(WORKSPACE) --override-config "$$cfg" \
		--remove-existing-container $(SSH_MOUNT); \
	st=$$?; rm -rf "$$(dirname "$$cfg")"; exit $$st

## Run all tests (tools, podman, env, mise lockfile freshness + audit)
test-all: test-tools test-podman test-env test-mise-lockfile test-mise test-qemu

## Alias for test-all
test: test-all

## Verify CLI tools, Python packages, and user config inside the devcontainer
test-tools:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-tools.sh

## Diagnostic sandbox primitive smoke test (runtime failures require REQUIRE_SANDBOX_PRIMITIVES=true to fail)
test-sandbox-primitives:
	$(DEVCONTAINER) exec --workspace-folder $(WORKSPACE) /workspace/igou-devenv/tests/test-sandbox-primitives.sh

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
## Uses the same MISE_VERSION as the Dockerfile. If that exact mise is not
## installed locally, bin/run-pinned-mise bootstraps it in a throwaway CentOS
## container via GPG-signed upstream checksums. Mise only writes to mise.lock if
## the file already exists; we touch it before invoking.
## Stash the previous lockfile so a transient failure (e.g. GitHub API
## rate limit, network blip) doesn't wipe the committed mise.lock.
mise-lock:
	@[ -f mise.lock ] && cp mise.lock mise.lock.bak || touch mise.lock
	@if MISE_LOCKED=0 "$(CURDIR)/bin/run-pinned-mise" mise install --yes && [ -s mise.lock ]; then \
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

# ---------------------------------------------------------------------------
# Release (CalVer) — dispatch the GitHub Actions release workflows on demand
# (e.g. a mid-week release). These wrap `gh workflow run`, so they need a gh
# token with Actions: write (or use the Actions UI). The Monday cron runs the
# equivalents automatically. Release PROMOTES the current tested :latest by
# digest, so make sure the latest push to main has a green build.yaml first.
# ---------------------------------------------------------------------------
RELEASE_REPO ?= igou-io/igou-devenv
WF           ?= release.yaml

## Cut a release now: promote the tested :latest to a dated CalVer tag + Release.
## Optional: VERSION=2026.06.18-2 (tag override), FORCE=true (ignore skip guards).
release:
	gh workflow run release.yaml --repo $(RELEASE_REPO) \
		$(if $(VERSION),-f version=$(VERSION)) \
		$(if $(FORCE),-f force=$(FORCE))
	@$(MAKE) --no-print-directory release-watch

## Dry-run a release: resolve + plan only (no promote/tag/release).
release-dry-run:
	gh workflow run release.yaml --repo $(RELEASE_REPO) -f dry_run=true
	@$(MAKE) --no-print-directory release-watch

## On-demand mise prep: regenerate mise.lock on the open Renovate mise PR and merge it.
release-prepare:
	gh workflow run release-prepare.yaml --repo $(RELEASE_REPO)
	@$(MAKE) --no-print-directory release-watch WF=release-prepare.yaml

## Watch the latest run of WF (default release.yaml).
release-watch:
	@sleep 8; \
	id=$$(gh run list --repo $(RELEASE_REPO) --workflow $(WF) --limit 1 --json databaseId --jq '.[0].databaseId'); \
	echo "Watching $(WF) run $$id ..."; \
	gh run watch "$$id" --repo $(RELEASE_REPO) --exit-status

help: ## Show available targets
	@awk '/^## /{if(!desc) desc=substr($$0,4); next} /^[a-zA-Z_-]+:/{if(desc){split($$1,a,":"); printf "  \033[36m%-25s\033[0m %s\n", a[1], desc} desc=""} !/^##/ && !/^[a-zA-Z_-]+:/{desc=""}' $(MAKEFILE_LIST)
