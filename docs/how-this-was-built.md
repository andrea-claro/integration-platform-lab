# How this was built

The project is built AI-first: a coding agent implements one task from [PLAN.md](../PLAN.md) at a
time, following [CLAUDE.md](../CLAUDE.md); Andrea reviews every change before it is merged.
Each session is logged below: task, what the agent produced, what was verified, what is open,
and a human review section.

---

## 2026-11-15 — Phase 0 foundations + Python services

**Tasks:** 0.2 repo skeleton · 0.3 k3d config · 0.4 OpenTofu bootstrap · 0.5 Makefile ·
2.3–2.5 service code (ahead of plan, requested in the session) · secrets workflow (`make env`,
`make seal`, plain-secret check).

**Produced**

- Repository skeleton per PLAN §4, MIT licence, `.gitignore`, `.env.example`, optional pre-commit
  hooks in `tools/pre-commit-config.yaml` (to be activated by a human).
- `cluster/k3d.yaml`: k3s v1.35.10, Traefik disabled, API and HTTPS bound to 127.0.0.1 only.
- `infra/bootstrap`: OpenTofu, helm provider 3.3.0, argo-cd chart 10.18.0 (Argo CD v3.6.1),
  argocd-apps 2.0.8 for the root Application; context guard (`k3d-*` only); lock file for
  macOS Intel/ARM and Linux.
- `gitops/root` (app-of-apps) with a first child, `platform-base`: the five domain namespaces
  with Pod Security Admission labels.
- Three Python 3.12 services with multi-stage Dockerfiles (`test` stage runs ruff + pytest,
  `runtime` stage non-root uid 10001), a Docker Compose dev stack (Mosquitto 2.1.2,
  Apache Kafka 4.3.2 in KRaft mode) and a smoke test.
- `tools/Dockerfile`: pinned linter image so `make lint` needs only Docker.

**Verified (in the agent's sandbox)**

- `make test` equivalent: 61 unit tests green, ruff clean.
- `make lint` equivalent: secret scan, yamllint, shellcheck, ruff, kustomize + kubeconform
  (including the Argo CD `Application` CRD schema), `tofu fmt` + `validate` — all green.
- Compose stack end to end: readings flow simulator → MQTT → Kafka → API.
- Failure tests: wrong Kafka hostname → bridge unready, `bridge_kafka_up 0`, clear DNS error in
  the logs; 40 s Kafka outage → 0 messages lost, API fresh again ~17 s after Kafka restart.
- `make cluster` + `tofu apply` ran up to the Helm install; pods could not start in the sandbox
  (nested container runtime limits), so Argo CD health is **not yet verified**.

**Changed during the session (agent self-corrections)**

- The first bridge version acknowledged MQTT messages before Kafka confirmed them; the outage
  test showed this could lose data. Now PUBACK is sent only after delivery (manual ack).
- librdkafka reconnect errors flooded the logs (one line every ~50 ms): added a dedup filter and
  routed librdkafka logs through the JSON formatter.
- Consumer `session.timeout.ms` lowered from 45 s to 10 s: the API took ~45 s to resume after a
  broker restart.
- First `make dev-up` on the Mac: all three services crash-looped with
  `No module named <pkg>.__main__`. Cause: the files reached the Mac with mode 600, `COPY` kept it,
  and the runtime user (uid 10001) could not read root-owned code; the `test` stage runs as root,
  so `make test` was green. Fix: `chmod -R a+rX` on the code in the runtime stage, plus a build
  step that imports the app **as uid 10001**, so this class of error fails the build instead of
  the container. Reproduced and verified with a 600/700 build context.

**Open questions / assumptions**

- Pod Security: `baseline` enforced, `restricted` in warn/audit; `observability` is
  `privileged` for node-exporter — revisit in Phase 3.
- Unit tests live next to each service (`services/<name>/tests`) rather than in `tests/`.

**Phase 0 acceptance (verified on the Mac, 2026-11-16):** `make cluster && make bootstrap` →
Argo CD v3.6.1 healthy; `root` and `platform-base` Synced/Healthy; five domain namespaces created by
Argo CD. Issues hit on the way: an old OpenTofu 1.8.5 on PATH (fixed with the pinned 1.13.9 from
`scripts/install-tools-macos.sh`), the repository URL (now `integration-platform-lab`), and a local
DNS outage unrelated to the project.

**Decisions (Andrea, same day)**

- Exposure: reuse the Cloudflare Tunnel connector already running on the Mac (no cloudflared in
  the cluster, no tunnel token in this repo); Argo CD is never published, local only. PLAN.md §2,
  §3, 4.4 and CLAUDE.md updated accordingly.
- Repository: public at `github.com/andrea-claro/integration-platform-lab`; every
  repoURL, the bootstrap default and the image source labels point there.
- Security posture: the hard requirement is that nothing is reachable from outside except the
  explicit public hostnames; inside the local cluster, pragmatic settings are acceptable. Current
  Pod Security levels are kept.

**Human review:** _to be filled in by Andrea_

---

## 2026-11-16 — Phase 1, steps 1–2: gateway, internal CA, Sealed Secrets

**Tasks:** 1.1 Gateway API + Envoy Gateway · 1.2 cert-manager internal CA · 1.3 Sealed Secrets and
`make seal` helpers. Plan approved by Andrea before implementation (CLAUDE.md: exposure and secrets).

**Produced**

- Argo CD Applications (app-of-apps): `cert-manager` (v1.21.3), `envoy-gateway` (v1.9.3, public
  OCI chart, Gateway API v1.6.1), `sealed-secrets` (chart 2.22.0, controller 0.41.2),
  `platform-pki`, `platform-gateway`, and a temporary `apps-echo`.
- PKI: self-signed root CA (10 years, ECDSA P-256) → `ClusterIssuer internal-ca` → 90-day gateway
  certificate (`*.ipl.localhost`, renewed 30 days before expiry).
- `GatewayClass envoy` + `EnvoyProxy` (small resources, LoadBalancer on the k3d loopback mapping)
  + `Gateway public` (HTTPS 443; only namespaces labelled `gateway-access=true` may attach routes).
- Echo service (`traefik/whoami`, non-root, read-only root filesystem) and its `HTTPRoute`.
- `scripts/seal-key.sh` + `make seal-backup`; `make bootstrap` restores the key first, so a
  recreated cluster can still decrypt the committed SealedSecrets.
- `tests/smoke/phase1-gateway.sh` + `make smoke`; ADR-005 with the documented exception to the
  "no Bitnami" rule (the Sealed Secrets project's own chart and image).

**Verified (agent sandbox)**

- Versions checked against each project's docs for the pinned release (Envoy Gateway
  compatibility matrix: v1.9 supports Kubernetes 1.35; Argo CD 3.6 native OCI Helm sources).
- `helm template` of the three charts with the chosen values.
- Server-side dry-run of every manifest against the real CRDs of the pinned charts, in a k3s
  v1.35.10 API server: all accepted. No Pod Security warnings, even at `restricted`.
- `make lint` green; shellcheck now also covers `tests/smoke/`. A bash 3.2 incompatibility
  (empty array under `set -u`) caught and fixed in the smoke test.

**Verified on the Mac (2026-11-16):** all Argo CD apps Synced/Healthy; `make smoke` 5/5 PASS (HTTPS
through the gateway, certificate issued by the internal root CA); `make seal-backup` saved the
controller key; `make seal` produced six SealedSecrets (no plain values, checked before commit).

**Found during verification:** the `.gitignore` rule `secrets/` was not anchored and silently
ignored `gitops/observability/secrets/`, so two SealedSecrets were missing from `git status`.
Anchored to `/secrets/`. Also: `mosquitto_passwd` warned about a world-readable temp file; the
seal script now creates it with mode 600 (the in-cluster broker will mount it read-only, 0400).

**Human review:** _to be filled in by Andrea_

---

## 2026-11-16 — Phase 1, step 3: AppProjects, RBAC, NetworkPolicies, quotas

**Tasks:** 1.4 AppProject per domain and RBAC checks · 1.5 default-deny NetworkPolicies with explicit
allows · 1.6 ResourceQuota and LimitRange per namespace. Plan approved by Andrea before
implementation (CLAUDE.md: RBAC and NetworkPolicies). From this step on the agent delivers through
pull requests; Andrea reviews and merges.

**Produced**

- Five AppProjects. `platform` is the only one with cluster-scoped kinds, from an explicit allow
  list built from what the pinned charts actually render; the domain projects are confined to their
  namespace and cannot change NetworkPolicies, ResourceQuotas or LimitRanges.
- `platform-guardrails` Application: default deny in every domain namespace plus DNS and Prometheus
  scraping; `platform` adds Kubernetes API egress for the controllers, public ingress to the Envoy
  proxies (10443), proxies → opted-in namespaces and → xDS; `apps` accepts only the proxies.
  Every rule carries a comment explaining why; the flow table is in `gitops/platform/guardrails/README.md`.
- ResourceQuotas sized on PLAN §7 (CPU requested, never limited) and a LimitRange with defaults.
- `tests/smoke/phase1-security.sh`: guardrails present, iot → apps blocked, `kubectl auth can-i`
  checks for the workload service account, no service account bound to cluster-admin, no
  Application left in the default project.

**Design notes**

- Checked in the kube-router source that traffic from the node itself is always accepted
  (`--src-type LOCAL`), so kubelet probes and API server → webhook calls need no rule. Egress from
  pods to the API server does need one: `kubernetes.default` is DNATed to the node IP on 6443.
- The cert-manager webhook has `failurePolicy: Fail`, so it must stay reachable from the API server
  (it is, as node-local traffic); the Envoy Gateway topology webhook is `Ignore`.
- Envoy listens on 10443 for the 443 listener (Envoy Gateway shifts ports below 1024 by 10000).

**Verified (agent sandbox):** lint green; every manifest accepted by a k3s v1.35.10 API server with
the real CRDs; guardrails applied for real, then every chart pod (plus the Envoy proxy and the
network probe pod) created in server-side dry-run: all admitted by LimitRange, ResourceQuota and
Pod Security, totals within the quotas even with the charts' default resources.

**Verified on the Mac (2026-11-16):** all 8 Applications Synced/Healthy in their projects; `make smoke`:
gateway checks 5/5 PASS *through* the new policies; guardrails present in all five namespaces;
`kubectl auth can-i` checks and the cluster-admin check PASS; iot → apps blocked.

**Corrected after the first run:** the probe expected a timeout (curl exit 28) but got exit 7
(connection refused in 4 ms) and reported "inconclusive". The kube-router source confirms it
`REJECT`s denied traffic rather than dropping it, so 7 is the correct "blocked" signal. The test now
accepts 7 or 28, after checking that `echo` has ready endpoints (a Service without backends is
refused the same way and must not pass for a policy block).

**Phase 1 acceptance met:** echo over HTTPS through the gateway with the internal CA; a pod in `iot`
cannot reach `apps`; `kubectl auth can-i` checks scripted in `tests/smoke`.

**Human review:** _to be filled in by Andrea_

---

## 2026-11-17 — Phase 2: integration workloads on the cluster

**Tasks:** 2.1 Strimzi + Kafka · 2.2 Mosquitto · 2.3–2.5 the three services on Kubernetes ·
2.6 API route with API-key auth and rate limits · 2.7 CI image publishing. Plan approved by Andrea
on 2026-11-16 (CLAUDE.md: NetworkPolicies, secrets, exposure).

**Recovered work.** The first Phase 2 session ended before anything was pushed. Its commands were
still in the session transcript, so the finished parts (CI workflow, OpenAPI key scheme, Strimzi and
Kafka manifests, NetworkPolicies) were replayed from it onto a fresh branch and re-validated rather
than rewritten. Lesson: push the branch after every commit, even before the PR is ready.

**Produced**

- `.github/workflows/images.yaml`: per service, the `test` stage (ruff + pytest) and a runtime build
  on every PR; on `main` a push to `ghcr.io/<owner>/ipl-<service>` tagged with the version from
  `pyproject.toml` and `sha-<commit>`. Version tags are immutable; the job fails if `gitops/` pins a
  different version, or if a PR changes an already published service without bumping it.
  `make build`/`make import` use the same tags, so the cluster can run local builds first.
- Strimzi 1.3.1 (OCI chart, `platform` project) and the `streaming-kafka` Application: Kafka 4.3.2
  in KRaft mode, one dual-role node, topics `telemetry.raw`/`telemetry.dlq`, Topic Operator, Kafka
  Exporter.
- `iot`: Mosquitto 2.1.2 (one user per client, topic ACL, persistence on a 256 Mi volume),
  device simulator and MQTT→Kafka bridge, one Application each.
- `apps`: telemetry-api (replaces the echo service), HTTPRoutes for `/v1` and the public docs,
  Envoy Gateway `SecurityPolicy` (API key from the existing SealedSecret) and
  `BackendTrafficPolicy` (local rate limits: 20/min for the published demo key, 300/min otherwise).
- NetworkPolicies for every new flow, each with a "why" comment; flow table in
  `gitops/platform/guardrails/README.md`.
- `tests/smoke/phase2-integration.sh`; the Phase 1 smoke tests now target the API.

**Design notes**

- Envoy Gateway v1.9.3 orders the API-key filter before the local rate limit
  (`internal/xds/translator/httpfilters.go`), so the rate limit can select on the `x-client-id`
  header the auth filter sets. Envoy overwrites that header, so a client cannot pick its own budget.
- Mosquitto 2.1 warns, and announces it will refuse, when the password or ACL file is not owned by
  the broker user (reproduced with the real image). Secret files are root-owned, so an init
  container copies them as uid 1883, mode 0400, into an in-memory volume.
- Simulator and bridge run as one replica with `Recreate`: fixed MQTT client ids and a persistent
  session for the bridge (two pods would take the session from each other).
- Kafka ingress comes from the NetworkPolicy Strimzi generates from `networkPolicyPeers`; the
  guardrails only add the matching egress. Pod labels and ports checked in the Strimzi 1.3.1 source.
- Secret volume modes are written in decimal (`288` = `0440`): a leading-zero octal can be read
  as decimal by YAML 1.2 tooling.
- Memory requests from measured idle RSS (simulator ~30 MiB, bridge ~40 MiB, API ~60 MiB):
  48/64/96 MiB, 208 MiB in total against the 384 MiB of PLAN §7.

**Verified (agent sandbox)**

- Unit tests: 63 green (16 + 28 + 19), ruff clean (Python 3.13 venvs; `make test` and CI run them in
  the images' Python 3.12 `test` stage).
- `scripts/lint.sh` green with the same pinned tool versions as the toolbox image (the image itself
  could not be built: Docker Hub rate limit). yamllint caught one over-long line in the workflow.
- k3s v1.35.10 API server with the CRDs of every pinned chart: namespaces and guardrails applied for
  real, then every manifest (root Applications and AppProjects, Kafka, iot, apps, gateway policies,
  the rendered Strimzi chart) accepted in server-side dry-run. Pods built from every Deployment
  template admitted by Pod Security (no `restricted` warnings), LimitRange and ResourceQuota.
- Mosquitto config, password file and ACL tested with the real 2.1.2 image: publish/subscribe
  allowed per ACL, wrong password refused, the simulator cannot read the topic, no ownership warnings.

Not verifiable in the sandbox: pods running, NetworkPolicy enforcement, Argo CD project checks at
sync time, the GHCR publish. These are covered by `make smoke` on the Mac.

**Found during verification on the Mac (2026-11-17):** the Kafka pod crash-looped with
`Failed to retrieve Secret ipl-dual-role-0`. Strimzi brokers read their own configuration Secret
through the Kubernetes API at startup (`KubernetesSecretConfigProvider`), and the guardrails gave
API egress only to the operator and the Topic Operator. Fixed by an API egress rule for the Kafka
pod. The sandbox dry-run could not catch it, because NetworkPolicies are enforced only where pods
run. Also: the k3d cluster had stopped (Docker restart) and `k3d image import` still printed
"Successfully imported"; `make import` now refuses to run when the cluster is not running.

**Verified on the Mac (2026-11-17), after the fix:** all 13 child Applications Synced/Healthy;
`make smoke` all PASS: 10 devices, newest reading 4 s old through the gateway, 401 without or with a
wrong key, burst of 30 with the demo key → 20 × 200 and 10 × 429, admin key unaffected.
**Phase 2 acceptance met.**

**Open questions / assumptions**

- GHCR packages are private on first publish: make the three packages public (once), or use
  `make import`.
- Plain MQTT and Kafka inside the cluster (NetworkPolicies + authentication on MQTT); TLS and Kafka
  client authentication are later hardening steps.

**Human review:** _to be filled in by Andrea_

---

## 2026-11-17 — Phase 3 (lean): observability

**Tasks:** 3.1–3.5. Scope reduced the same evening at Andrea's request ("reach the end of the lab
sooner, still showing the point"): see PLAN §6, scope update. Plan approved in the same exchange.

**Produced**

- `kube-prometheus-stack` 93.3.1 (Prometheus Operator v0.95.2, Prometheus v3.16, Grafana 13.3)
  through the `platform` project: no node-exporter, no k3s control-plane monitors, no default rules
  or dashboards, admission webhooks off (rules are checked by promtool), ~650 MiB requested.
  Prometheus selects monitors and rules from `observability` only.
- `observability-config` (project `observability`): PodMonitors for the three services, Kafka
  Exporter and cert-manager; five alerts; the "Integration Platform overview" dashboard as a
  ConfigMap; the existing Grafana admin SealedSecret.
- Alerts, symptom first: `TelemetryPipelineStalled` (also fires when the bridge is not scraped at
  all), `KafkaConsumerLagHigh`, `CertificateExpiringSoon`, `PodCrashLooping`, `TargetDown`. Each has
  a runbook and promtool tests that fire and do not fire. `PodCrashLooping`'s runbook uses the
  real Kafka crash loop found during the Phase 2 verification as its example.
- `scripts/test-rules.sh` (`make test-rules`, also in `make lint`): extracts the rule groups from the
  PrometheusRule manifests, runs `promtool check` and `test`, fails if an alert has no runbook.
  promtool added to the toolbox image.
- NetworkPolicies for `observability`; the namespace now enforces the `baseline` Pod Security
  Standard (node-exporter was the only reason for `privileged`).
- Telegram removed everywhere (SealedSecret, `.env.example`, seal script): cut from scope.
- `tests/smoke/phase3-observability.sh`; `make grafana-ui`, `make prometheus-ui`, `make alertmanager-ui`.

**Verified (agent sandbox)**

- promtool: 5 rules, all tests pass. Mutation check: weakening a threshold or dropping the
  `or vector(0)` branch makes the matching test fail, so the tests do bite.
- `scripts/lint.sh` green (yamllint caught two over-long lines; PromQL folded).
- k3s v1.35.10 API server with the chart CRDs: root Applications, `gitops/observability` and the
  rendered chart (36 objects) accepted in server-side dry-run; Grafana, kube-state-metrics and
  operator pods admitted at `baseline` with no `restricted` warnings, within quota and LimitRange.

Not verifiable in the sandbox: scraping through the NetworkPolicies, Grafana loading the dashboard.

**Human review:** _to be filled in by Andrea_

---
