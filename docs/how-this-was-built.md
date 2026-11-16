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
