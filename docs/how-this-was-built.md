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
