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
# Empty = each service's version from its pyproject.toml, the tag pinned in gitops/.
IMAGE_TAG    ?=
SERVICES     := device-simulator mqtt-kafka-bridge telemetry-api
TOOLBOX      := ipl-toolbox:local
COMPOSE      := docker compose -f services/compose.yaml --project-name ipl-dev

# Load .env into a recipe's environment (never echoed).
LOAD_ENV := set -a; [ -f .env ] && . ./.env; set +a

.PHONY: help
help: ## List targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_%-]+:.*## /{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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

# --- Observability UIs (port-forward, local only) ----------------------------
.PHONY: grafana-ui prometheus-ui alertmanager-ui
grafana-ui: ## Grafana on http://localhost:3000 (user admin, password GRAFANA_ADMIN_PASSWORD in .env)
	kubectl --context $(KUBE_CONTEXT) -n observability port-forward svc/kps-grafana 3000:80

prometheus-ui: ## Prometheus on http://localhost:9090 (targets, rules, alerts)
	kubectl --context $(KUBE_CONTEXT) -n observability port-forward svc/kps-prometheus 9090:9090

alertmanager-ui: ## Alertmanager on http://localhost:9093
	kubectl --context $(KUBE_CONTEXT) -n observability port-forward svc/kps-alertmanager 9093:9093

# --- Secrets -----------------------------------------------------------------
.PHONY: seal seal-backup check-secrets
seal: ## Seal secrets from .env into SealedSecret manifests (needs the controller)
	@scripts/seal-secrets.sh $(SECRETS)

seal-backup: ## Back up the Sealed Secrets key to secrets/ (gitignored; restored by bootstrap)
	@KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/seal-key.sh backup

check-secrets: ## Fail on plain Secret manifests or tracked .env files
	@scripts/check-no-plain-secrets.sh

# --- Images ------------------------------------------------------------------
# CI publishes the same names to GHCR (.github/workflows/images.yaml). `make import`
# loads local builds under the pinned tags, so the cluster can run them before the
# GHCR packages exist or are public (imagePullPolicy IfNotPresent).
svc_version = $(shell sed -n 's/^version = "\(.*\)"$$/\1/p' services/$(1)/pyproject.toml)
svc_image   = $(IMAGE_PREFIX)$(1):$(or $(IMAGE_TAG),$(call svc_version,$(1)))

.PHONY: build import cluster-running
build: ## Build the service images (runtime target), tagged with their version
	@set -e; $(foreach s,$(SERVICES),echo "==> $(call svc_image,$(s))"; \
	  docker build --target runtime -t $(call svc_image,$(s)) services/$(s);)

import: cluster-running build ## Build and import the images into k3d (fast local iteration)
	k3d image import -c $(CLUSTER_NAME) $(foreach s,$(SERVICES),$(call svc_image,$(s)))

# k3d reports "Successfully imported" even when the node container is stopped.
cluster-running:
	@running="$$(k3d cluster list $(CLUSTER_NAME) -o json 2>/dev/null | jq -r '.[0].serversRunning // 0')"; \
	if [ "$${running:-0}" -lt 1 ]; then \
	  echo "cluster $(CLUSTER_NAME) is not running: k3d cluster start $(CLUSTER_NAME) (or make cluster)"; exit 1; \
	fi

# --- Quality -----------------------------------------------------------------
.PHONY: test test-rules lint toolbox smoke
test: ## Unit tests + ruff for every service, inside Docker (test stage)
	@set -e; for s in $(SERVICES); do \
	  echo "==> $$s"; \
	  docker build --target test --progress=plain -t ipl-test-$$s services/$$s; \
	done

test-rules: toolbox ## promtool unit tests for every alert rule, plus the runbook check
	docker run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR):/work" $(TOOLBOX) scripts/test-rules.sh

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

# --- Incident lab (PLAN 4): live faults, recovery through Argo CD -------------
.PHONY: incidents
incidents: ## List the incident scenarios (make break-<name> / make restore-<name>)
	@for d in incidents/*/; do n=$$(basename $$d); printf "  %-8s %s\n" $$n "$$(sed -n 's/^# Incident "[a-z]*": //p' $$d/inject.sh | head -1)"; done

break-%: ## Inject an incident scenario (e.g. make break-dns), then follow its runbook
	@test -x incidents/$*/inject.sh || { echo "unknown scenario '$*' (make incidents)"; exit 1; }
	@KUBE_CONTEXT=$(KUBE_CONTEXT) incidents/$*/inject.sh

restore-%: ## Restore a scenario through GitOps and print a timeline (e.g. make restore-dns)
	@test -x incidents/$*/restore.sh || { echo "unknown scenario '$*' (make incidents)"; exit 1; }
	@KUBE_CONTEXT=$(KUBE_CONTEXT) incidents/$*/restore.sh

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
