# CLAUDE.md

## What this project is

**integration-platform-lab** is a small integration platform on Kubernetes, run locally in containers at zero cost
and managed entirely through GitOps.

IoT devices (simulated) publish telemetry over MQTT. A bridge moves it into Kafka. A telemetry API consumes Kafka
and is exposed through Envoy Gateway with TLS, rate limiting and authentication. Prometheus, Alertmanager and
Grafana watch everything, and an **incident lab** injects realistic faults (expired certificate, wrong DNS name,
blocked network path, OOM) with runbooks showing how to diagnose and fix them end to end.
Selected read-only views are published on the internet through Cloudflare Tunnel.

It is a hands-on lab on operating an integration platform (streaming, API management,
file transfer, IoT). Reliability, security, clear operations and troubleshooting matter more than features.

The full plan, phases and acceptance criteria are in **PLAN.md**. Work only on the task you are given.

## Hard rules

- **Zero cost.** No cloud resources, no paid services. Never apply anything in `infra/envs/aws` (validate only).
- **GitOps is the only deployment path.** Everything in the cluster comes from `gitops/` through Argo CD.
  Manual `kubectl apply` is allowed only in `make bootstrap` and in `incidents/*/inject.sh` / `restore.sh`.
- **Secrets:** never commit plain `Secret` manifests or real values. Use SealedSecrets; local values live in `.env`
  (gitignored) and every variable is listed in `.env.example` with a placeholder.
- **Public surface** only through the Cloudflare Tunnel connector on the Mac, and only for hostnames with an explicit
  HTTPRoute (`status.`, `api.`). Never publish Argo CD or other admin UIs. No NodePort or hostPort exposure besides
  the local k3d port mapping, which binds to 127.0.0.1 only.
- **No ingress-nginx** (retired) → Gateway API with Envoy Gateway. **No Bitnami charts or images** → official charts/images only.
- **Pin versions** of every chart and image; check the docs of the pinned version before writing CRDs or policies.
- **English only** in code, comments, docs and commit messages. **No employer names or branding.**
- **Ask before** adding a component, changing the architecture in PLAN.md §3 or raising resource requests above PLAN.md §7.

## Stack

- **Cluster:** k3d (k3s in Docker), Traefik disabled.
- **Bootstrap IaC:** Terraform/OpenTofu with the Helm provider (Argo CD + root Application).
- **Delivery:** Argo CD app-of-apps; Helm for third-party charts, Kustomize for our manifests.
- **Networking:** Gateway API + Envoy Gateway, cert-manager (internal CA), NetworkPolicies, CoreDNS.
- **Integration:** Strimzi Kafka (KRaft, 1 broker), Eclipse Mosquitto.
- **Our services (Python 3.12):** `device-simulator`, `mqtt-kafka-bridge`, `telemetry-api` (FastAPI). Images on GHCR.
- **Observability:** kube-prometheus-stack, Alertmanager → Telegram.
- **Secrets:** Sealed Secrets. **Exposure:** existing Cloudflare Tunnel connector on the Mac → Envoy Gateway; admin UIs local only.
- **Quality:** ruff, pytest, yamllint, kubeconform, kube-linter, Trivy config, promtool.

## Conventions

- **Namespaces:** `platform`, `streaming`, `iot`, `apps`, `observability`, `argocd`.
- **Every workload:** its own ServiceAccount, resource requests and limits, liveness/readiness probes,
  `runAsNonRoot`, read-only root filesystem where possible, labels `app.kubernetes.io/*`.
- **NetworkPolicies:** default deny per namespace; every allow rule has a comment saying why it exists.
- **RBAC:** least privilege; no `cluster-admin` for workloads; Argo CD `AppProject` per domain.
- **Services:** structured JSON logs, `/healthz`, `/metrics` (Prometheus), config via env vars, graceful shutdown.
- **Alerts:** every PrometheusRule has a `promtool` unit test, a `runbook_url` annotation and a runbook in `docs/runbooks/`.
- **Commits:** small, conventional prefixes (`feat:`, `fix:`, `test:`, `infra:`, `gitops:`, `docs:`, `ci:`).

## Commands

Created in Phase 0; keep this list up to date.

- `make help` — list all targets; `make prereqs` — check the CLI tools on the Mac
- `make env` — create/complete `.env` (gitignored) and generate local secrets
- `make cluster` / `make down` — create or delete the k3d cluster
- `make bootstrap` — install Argo CD and the root Application (OpenTofu; `TF=terraform` to switch)
- `make status` — Argo CD apps, pods not ready, firing alerts
- `make argocd-password` / `make argocd-ui` — admin password, UI on http://localhost:8080
- `make seal` — seal secrets from `.env` into SealedSecret manifests; `make check-secrets` — plain-secret scan
- `make test` — ruff + pytest per service in the image `test` stage; `make lint` — repo checks in the toolbox image
- `make build` / `make import` — build service images, import them into k3d
- `make dev-up` / `make dev-smoke` / `make dev-down` — services with Docker Compose (local dev only, not a deployment path)
- `make break-<scenario>` / `make restore-<scenario>` — incident lab (Phase 4)

## Environment notes

- Host: macOS (Intel x64) with Docker Desktop, memory ≥ 8 GB for this project.
- Another project (`partner-file-gateway`, LocalStack + SFTPGo) may run at the same time: respect the resource budget.
- Argo CD syncs from the public GitHub repo, so changes take effect only after they are pushed.

## How we work (AI-first)

1. Restate the task and its acceptance criteria from PLAN.md, then propose a short plan.
   Wait for approval on anything that touches architecture, RBAC, NetworkPolicies, secrets or exposure.
2. Implement in small steps, tests or validation first where possible.
3. Before saying a task is done: run lint, tests and manifest validation and show the results.
   Never mark a task done with failing checks.
4. Summarise what changed, the assumptions you made and any open questions.
5. Tick the task in PLAN.md and append an entry to `docs/how-this-was-built.md`:
   date, task, what you produced, and a "Human review" placeholder for Andrea to fill in.
