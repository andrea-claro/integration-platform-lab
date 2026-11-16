# integration-platform-lab — task runner.
# Compatible with the GNU make 3.81 that ships with macOS.
SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= ipl
KUBE_CONTEXT ?= k3d-$(CLUSTER_NAME)
TF           ?= tofu
LINT_IN_DOCKER ?= 1

GITHUB_OWNER := $(or $(shell sed -n 's/^GITHUB_OWNER=//p' .env 2>/dev/null),andrea-claro)
IMAGE_PREFIX ?= ghcr.io/$(GITHUB_OWNER)/ipl-
IMAGE_TAG    ?= dev
SERVICES     := device-simulator mqtt-kafka-bridge telemetry-api
TOOLBOX      := ipl-toolbox:local
COMPOSE      := docker compose -f services/compose.yaml --project-name ipl-dev

# Load .env into a recipe's environment (never echoed).
LOAD_ENV := set -a; [ -f .env ] && . ./.env; set +a

.PHONY: help
help: ## List targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Setup ------------------------------------------------------------------
.PHONY: env prereqs
env: ## Create/complete .env (gitignored) and generate local secrets
	@scripts/init-env.sh

prereqs: ## Check the CLI tools needed on the Mac
	@missing=0; for b in docker k3d kubectl $(TF) kubeseal jq; do \
	  if command -v $$b >/dev/null; then printf "  ok       %s\n" $$b; \
	  else printf "  MISSING  %s\n" $$b; missing=1; fi; done; \
	docker info >/dev/null 2>&1 || { echo "  Docker daemon not running"; missing=1; }; \
	exit $$missing

# --- Cluster lifecycle (PLAN 0.3-0.5) ---------------------------------------
.PHONY: cluster down bootstrap status argocd-password argocd-ui
cluster: ## Create the k3d cluster (Traefik disabled)
	@if k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1; then \
	  echo "cluster $(CLUSTER_NAME) already exists"; \
	else k3d cluster create --config cluster/k3d.yaml; fi
	@kubectl --context $(KUBE_CONTEXT) get nodes

down: ## Delete the k3d cluster
	k3d cluster delete $(CLUSTER_NAME)
	@rm -f infra/bootstrap/terraform.tfstate infra/bootstrap/terraform.tfstate.backup

bootstrap: ## Install Argo CD and the root Application (Terraform/OpenTofu)
	@$(LOAD_ENV); \
	set -e; \
	KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/seal-key.sh restore; \
	$(TF) -chdir=infra/bootstrap init -input=false; \
	$(TF) -chdir=infra/bootstrap apply -input=false -auto-approve \
	  -var "kube_context=$(KUBE_CONTEXT)" \
	  $${GITOPS_REPO_URL:+-var "gitops_repo_url=$$GITOPS_REPO_URL"} \
	  $${GITOPS_REVISION:+-var "gitops_revision=$$GITOPS_REVISION"}

status: ## Argo CD apps, pods not ready, firing alerts
	@KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/status.sh

argocd-password: ## Print the initial Argo CD admin password
	@kubectl --context $(KUBE_CONTEXT) -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

argocd-ui: ## Argo CD UI on http://localhost:8080 (port-forward, local only)
	kubectl --context $(KUBE_CONTEXT) -n argocd port-forward svc/argocd-server 8080:80

# --- Secrets -----------------------------------------------------------------
.PHONY: seal seal-backup check-secrets
seal: ## Seal secrets from .env into SealedSecret manifests (needs the controller)
	@scripts/seal-secrets.sh $(SECRETS)

seal-backup: ## Back up the Sealed Secrets key to secrets/ (gitignored; restored by bootstrap)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/seal-key.sh backup

check-secrets: ## Fail on plain Secret manifests or tracked .env files
	@scripts/check-no-plain-secrets.sh

# --- Images ------------------------------------------------------------------
.PHONY: build import
build: ## Build the service images (runtime target)
	@set -e; for s in $(SERVICES); do \
	  echo "==> $$s"; \
	  docker build --target runtime -t $(IMAGE_PREFIX)$$s:$(IMAGE_TAG) services/$$s; \
	done

import: build ## Build and import the images into k3d (fast local iteration)
	k3d image import -c $(CLUSTER_NAME) $(foreach s,$(SERVICES),$(IMAGE_PREFIX)$(s):$(IMAGE_TAG))

# --- Quality -----------------------------------------------------------------
.PHONY: test lint toolbox smoke
test: ## Unit tests + ruff for every service, inside Docker (test stage)
	@set -e; for s in $(SERVICES); do \
	  echo "==> $$s"; \
	  docker build --target test --progress=plain -t ipl-test-$$s services/$$s; \
	done

smoke: ## Acceptance checks against the running cluster (tests/smoke)
	@set -e; for t in tests/smoke/*.sh; do KUBE_CONTEXT=$(KUBE_CONTEXT) $$t; done

toolbox: ## Build the pinned linter image
	docker build -q -t $(TOOLBOX) tools >/dev/null

ifeq ($(LINT_IN_DOCKER),1)
lint: toolbox ## yamllint, shellcheck, ruff, kubeconform, tofu validate, secret check
	docker run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR):/work" $(TOOLBOX) scripts/lint.sh
else
lint:
	scripts/lint.sh
endif

# --- Local dev stack for the services (Docker Compose, not a deployment path) --
.PHONY: dev-up dev-down dev-logs dev-smoke
dev-up: ## Run Mosquitto + Kafka + the three services with Docker Compose
	$(COMPOSE) up -d --build --wait

dev-down: ## Stop the compose stack and delete its volumes
	$(COMPOSE) down -v

dev-logs: ## Follow the compose logs
	$(COMPOSE) logs -f --tail=50

dev-smoke: ## Check that readings flow simulator -> MQTT -> Kafka -> API
	@scripts/dev-smoke.sh http://127.0.0.1:8088
