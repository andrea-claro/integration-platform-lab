# integration-platform-lab — Execution plan

> Hands-on lab: running an integration platform (streaming, API management, IoT) reliably and securely.
> Companion of `partner-file-gateway` (file transfer). Owner: Andrea Claro · Plan date: 15 Nov 2026

## 1. Goal

Build, AI-first and GitOps-first, a small integration platform on Kubernetes that covers the core themes of integration platform operations:
streaming, API management and IoT, run reliably and securely, with networking, TLS, observability and
incident response done properly.

Everything runs locally in containers at zero cost. Selected read-only views are published through Cloudflare Tunnel.

What the project must prove to a reviewer:

1. Running workloads on Kubernetes: networking, Gateway API, RBAC, NetworkPolicies, resource management.
2. GitOps with Argo CD, Helm and Kustomize; infrastructure bootstrapped with Terraform/OpenTofu.
3. Infrastructure fundamentals: DNS, TLS/mTLS, load balancing, end-to-end troubleshooting.
4. Observability: Prometheus, Grafana, alerting, runbooks and incident follow-up.
5. Integration patterns: Kafka streaming, MQTT IoT ingestion, an API behind a managed gateway.
6. AWS awareness: a mapping of every local component to its EKS/AWS equivalent (and, later, a validate-only EKS target).

## 2. Constraints

- **Zero cost.** No cloud resources. Only free, open-source components.
- **Host:** MacBook Pro (Intel x64) with Docker Desktop. Docker memory **≥ 8 GB** for this project.
- **Runs in parallel with `partner-file-gateway`.** Agents may work on both; Andrea reviews both daily.
- **Exposure:** the Cloudflare Tunnel connector already running on the Mac (remote-managed, public hostnames set in the Cloudflare dashboard) → Envoy Gateway on `127.0.0.1:8443`; no inbound ports, no cloudflared in the cluster.
- **Public surface:** a shared read-only Grafana dashboard and the telemetry API docs, nothing else. Argo CD is never published (local only, `make argocd-ui`).
- **No ingress-nginx** (retired March 2026) → Gateway API. **No Bitnami charts or images** (free catalog discontinued in 2025).
- **Timeline:** MVP public by Mon 23 Nov; later phases follow from Tue 24 Nov.
- **Neutral branding:** no employer names or logos anywhere.

## 3. Architecture

```
             Cloudflare Tunnel (connector on the Mac → https://127.0.0.1:8443)
                         status.<domain>      api.<domain>
                                      │
                                      ▼
                    Envoy Gateway  (Gateway API, TLS from cert-manager internal CA)
                       │  HTTPRoutes · rate limit · API-key auth · (later) client mTLS
          ┌────────────┼────────────────────────┐
          ▼            ▼                        ▼
   telemetry-api    Grafana (shared        (no route: Argo CD UI is local only)
   (FastAPI)        dashboard)
          ▲
          │ consumes
   Kafka (Strimzi, KRaft, 1 broker) ◄── mqtt-kafka-bridge ◄── Mosquitto (MQTT) ◄── device-simulator

   Observability: kube-prometheus-stack (Prometheus, Alertmanager → Telegram, Grafana)
   Security: namespaces per domain · RBAC + Argo CD AppProjects · default-deny NetworkPolicies
             · ResourceQuota/LimitRange · one ServiceAccount per workload · Sealed Secrets
   Delivery: Terraform/OpenTofu bootstrap → Argo CD app-of-apps → Helm (3rd party) + Kustomize (own)
```

Namespaces: `platform` (gateway, cert-manager, sealed-secrets), `streaming`, `iot`, `apps`, `observability`, `argocd`.

### Local component → AWS/EKS equivalent

| Local | AWS / EKS | Notes for the README |
|---|---|---|
| k3d (k3s in Docker) | EKS | Single node locally; managed node groups on EKS |
| k3s service load balancer | AWS Load Balancer Controller (NLB/ALB) | Gateway API is supported on both |
| Envoy Gateway | Envoy Gateway or AWS LB Controller Gateway API | Same Gateway/HTTPRoute manifests |
| cert-manager internal CA | ACM / ACM Private CA | Expiry alerting identical |
| CoreDNS | Route 53 private hosted zones + CoreDNS | DNS troubleshooting scenario |
| ServiceAccount per workload | IRSA / EKS Pod Identity | Least privilege per workload |
| Sealed Secrets | AWS Secrets Manager + External Secrets, KMS | |
| Network isolation via NetworkPolicy | VPC design, security groups, PrivateLink | |
| Strimzi Kafka | Amazon MSK | |

### Design decisions (one short ADR each in `docs/adr/`)

- **ADR-001** k3d over kind/minikube: light, built-in load balancer, NetworkPolicy enforced out of the box.
- **ADR-002** Gateway API with Envoy Gateway instead of ingress-nginx.
- **ADR-003** Argo CD app-of-apps; Helm for third-party charts, Kustomize for our own manifests.
- **ADR-004** Strimzi Kafka in KRaft mode, single broker — dev trade-offs documented.
- **ADR-005** Secrets in Git only as SealedSecrets.
- **ADR-006** Local ↔ AWS mapping (table above).

## 4. Repository layout

```
integration-platform-portfolio/
├── PLAN.md                  this file
├── CLAUDE.md                instructions for coding agents
├── README.md
├── Makefile                 cluster, bootstrap, down, test, lint, break-*, status
├── .env.example             tunnel token, Telegram bot, demo API key (never real values)
├── cluster/                 k3d config (Traefik disabled)
├── infra/
│   ├── bootstrap/           Terraform/OpenTofu: Argo CD (Helm provider) + root Application
│   └── envs/aws/            EKS reference target, validate only (Phase 6)
├── gitops/
│   ├── root/                app-of-apps
│   ├── platform/            gateway, cert-manager, sealed-secrets, rbac, policies, quotas
│   ├── streaming/           strimzi operator, kafka cluster, topics
│   ├── iot/                 mosquitto, device-simulator, mqtt-kafka-bridge
│   ├── apps/                telemetry-api
│   └── observability/       kube-prometheus-stack values, dashboards, alert rules
├── services/                Python sources + Dockerfiles: device-simulator, mqtt-kafka-bridge, telemetry-api
├── incidents/               one folder per scenario: inject.sh, restore.sh, README
├── tests/                   pytest, promtool rule tests, smoke tests
└── docs/                    architecture.md, adr/, runbooks/, postmortems/, how-this-was-built.md
```

## 5. Phases and schedule

Every task is implemented by an AI coding agent from this plan, reviewed by Andrea and merged via PR.
"Done" means: acceptance criteria met and checks green.

### Phase 0 — Foundations (Mon 16 Nov)

- [ ] 0.1 **Prerequisites on the Mac (Andrea, manual):** k3d, kubectl, helm, OpenTofu or Terraform, kubeseal, argocd CLI, jq (cloudflared already runs on the Mac); Docker Desktop memory ≥ 8 GB; public GitHub repo; GHCR enabled.
- [x] 0.2 Repo skeleton (§4), MIT licence, `.gitignore`, `.env.example`.
- [ ] 0.3 `cluster/k3d.yaml`: one server, Traefik disabled, local port mapping for HTTPS testing.
- [ ] 0.4 `infra/bootstrap`: install Argo CD with the Helm provider and create the root Application pointing at `gitops/root`.
- [ ] 0.5 `Makefile` targets `cluster`, `bootstrap`, `down`, `status`.
- **Acceptance:** `make cluster && make bootstrap` → Argo CD healthy, root app `Synced/Healthy`.

### Phase 1 — Platform base via GitOps (Tue 17 – Wed 18 Nov)

- [ ] 1.1 Gateway API CRDs + Envoy Gateway; one `Gateway` with an HTTPS listener.
- [ ] 1.2 cert-manager with a self-signed root → internal CA `ClusterIssuer`; gateway certificate issued from it.
- [ ] 1.3 Sealed Secrets controller; `make seal` helper.
- [ ] 1.4 Namespaces, ServiceAccounts, Roles/RoleBindings, Argo CD `AppProject` per domain.
- [ ] 1.5 Default-deny NetworkPolicies per namespace + explicit allows (DNS, gateway → apps, apps → Kafka, Prometheus scraping).
- [ ] 1.6 ResourceQuota and LimitRange per namespace.
- **Acceptance:** an echo service answers over HTTPS through the gateway with the internal CA; a pod in `iot` cannot reach `apps` unless allowed; `kubectl auth can-i` checks scripted in `tests/smoke`.

### Phase 2 — Integration workloads (Wed 18 – Thu 19 Nov)

- [ ] 2.1 Strimzi operator; `Kafka` cluster in KRaft mode (1 broker); `KafkaTopic` resources; Kafka Exporter enabled.
- [ ] 2.2 Mosquitto MQTT broker (official image).
- [x] 2.3 `device-simulator` (Python): N virtual sensors publishing JSON telemetry to MQTT. *(code, tests, image; k8s manifests pending)*
- [x] 2.4 `mqtt-kafka-bridge` (Python): MQTT → Kafka topic `telemetry.raw`, with retries and structured logs. *(code, tests, image; k8s manifests pending)*
- [x] 2.5 `telemetry-api` (FastAPI): consumes Kafka, serves latest readings and per-device stats; OpenAPI docs. *(code, tests, image; k8s manifests pending)*
- [ ] 2.6 HTTPRoute for the API with local rate limiting and API-key auth (Envoy Gateway policies).
- [ ] 2.7 Images built and pushed to GHCR by CI; locally `k3d image import` for fast iteration.
- **Acceptance:** simulator → MQTT → Kafka → API returns fresh readings over HTTPS; no key → 401; burst above the limit → 429; unit tests green.

### Phase 3 — Observability (Fri 20 Nov)

- [ ] 3.1 kube-prometheus-stack with short retention and small resource requests.
- [ ] 3.2 ServiceMonitors/PodMonitors: Kafka Exporter, Envoy, cert-manager, our services (`/metrics`).
- [ ] 3.3 Grafana dashboard as code: "Integration Platform overview" (throughput, consumer lag, gateway latency/5xx, cert expiry, pod health).
- [ ] 3.4 PrometheusRules: `KafkaConsumerLagHigh`, `PodCrashLooping`, `CertificateExpiringSoon`, `GatewayHigh5xxRate`, `TargetDown`.
- [ ] 3.5 `promtool test rules` unit tests for every alert.
- [ ] 3.6 Alertmanager → Telegram (bot token as SealedSecret).
- **Acceptance:** every rule has a passing promtool test; a real alert reaches Telegram.

### Phase 4 — Incident lab & public exposure (Sat 21 – Sun 22 Nov)

- [ ] 4.1 Incident framework: `make break-<name>` / `make restore-<name>`. Faults are injected either as live drift (with Argo CD self-heal paused for that app) or as a bad commit on a branch; recovery always goes through Git/Argo CD.
- [ ] 4.2 **MVP scenarios:** `cert` (certificate expiring / expired on the gateway) and `dns` (bridge pointed at a wrong Kafka hostname).
- [ ] 4.3 For each scenario: runbook in `docs/runbooks/` (symptom → alert → diagnosis commands → root cause → fix) and a short postmortem in `docs/postmortems/`.
- [ ] 4.4 Public hostnames on the existing tunnel (Cloudflare dashboard) → `https://127.0.0.1:8443` (Envoy Gateway; origin server name = hostname): `status.<domain>` (shared read-only Grafana dashboard) and `api.<domain>` (API docs + demo key with tight rate limit). Tunnel config documented in `docs/exposure.md`; Argo CD stays local only.
- **Acceptance:** both scenarios reproducible end to end; public URLs work over HTTPS; Argo CD and every other hostname not reachable from outside.

### Phase 5 — CI, docs, polish (Sun 22 – Mon 23 Nov)

- [ ] 5.1 GitHub Actions: yamllint, kubeconform on rendered manifests, `helm lint`/`template`, kube-linter, Trivy config scan, `promtool test rules`, ruff + pytest, `tofu`/`terraform fmt` + `validate`, image build → GHCR.
- [ ] 5.2 README: what it is, architecture diagram, local ↔ AWS table, quickstart, incident lab walkthrough, live links.
- [ ] 5.3 `docs/how-this-was-built.md`: agent workflow, review checklist, examples of AI output corrected or rejected.
- [ ] 5.4 ADR-001 to ADR-006.
- **Acceptance:** CI green on `main`; a reviewer understands the platform and the incident lab in two minutes.

### Phase 6 — Next steps (from Tue 24 Nov)

- [ ] 6.1 Client mTLS for the API (Envoy Gateway client certificate validation, certs from cert-manager).
- [ ] 6.2 Scenarios `netpol` (missing allow rule) and `oom` (memory limit too low).
- [ ] 6.3 `infra/envs/aws` validate-only: VPC with private subnets, EKS, Pod Identity, VPC endpoints (PrivateLink), KMS, Route 53.
- [ ] 6.4 Integration with `partner-file-gateway`: processed-file events → Kafka topic `files.processed`.
- [ ] 6.5 OpenCost for a FinOps view; a read-only MCP server exposing platform status to AI agents.

## 6. Cut line

- **Must have by 23 Nov:** Phases 0–3, `status.<domain>` public, one incident scenario with runbook, README.
- **Cut first, in this order:** API-key auth (keep rate limit), second incident scenario, Telegram (keep Alertmanager UI), kube-linter/Trivy in CI.
- **Never cut:** GitOps as the only deployment path, default-deny NetworkPolicies, promtool tests, README "how this was built".

## 7. Resource budget

| Component | Memory request (approx.) |
|---|---|
| Kafka broker (KRaft) | 1 GiB |
| Prometheus (2-day retention) | 1 GiB |
| Argo CD | 512 MiB |
| Grafana, Alertmanager | 384 MiB |
| Envoy Gateway + proxy | 256 MiB |
| cert-manager, sealed-secrets, Mosquitto | 256 MiB |
| Our three services | 384 MiB |

Keep requests close to these values. If Docker runs out of memory with both projects up, stop one stack (`make down`) rather than raising limits blindly.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Not enough memory for both projects | Budget §7, short retention, one stack at a time if needed |
| Envoy Gateway policy features differ by version | Pin versions; check the docs of the pinned version before writing policies |
| Self-heal undoing injected faults | Pause self-heal per app inside `inject.sh`, resume in `restore.sh` |
| Secrets leaking through GitOps | SealedSecrets only; CI check that fails on plain `Secret` manifests |
| Mac asleep while visitors open the public URLs | Keep-awake while the demo is public; status note in README |
| Limited time | Cut line §6; small tasks with clear acceptance criteria |

## 9. AI-first workflow

- Agents work one task at a time from §5, on a branch, tests first where possible.
- Andrea reviews every PR: correctness, RBAC and NetworkPolicy scope, secrets, resource requests, consistency with ADRs.
- Every session is logged in `docs/how-this-was-built.md`: task, what the agent produced, what was changed or rejected, and why.
