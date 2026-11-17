# ADR-001: k3d (k3s in Docker) as the local cluster

- Status: accepted (2026-11-15)
- Context: Phase 0.3

## Context

The lab must run on one MacBook (Intel, Docker Desktop, ~8 GB for this project) next to another
project, at zero cost, and still behave like a real cluster: Services of type LoadBalancer,
NetworkPolicies that are actually enforced, persistent volumes.

## Decision

k3d v5 with k3s v1.35.10: one server node, Traefik disabled (ADR-002), API and the HTTPS port bound
to `127.0.0.1` only.

## Consequences

- k3s ships kube-router, which **enforces NetworkPolicies** out of the box. The default-deny
  guardrails are real, as the Phase 2 Kafka crash loop showed.
- Built-in service load balancer (servicelb) and local-path storage: the Envoy Gateway Service
  and the Kafka and Mosquitto volumes work without add-ons.
- One node: no scheduling, spreading or node-failure scenarios. Fine for this lab.
- **Datastore: embedded etcd (`--cluster-init`), not the default SQLite.** With the full stack
  (a dozen controllers renewing leases, Argo CD reconciling large CRDs), k3s on SQLite timed out
  and exited on the laptop ([postmortem](../postmortems/2026-11-17-k3s-control-plane-crash.md)).
  metrics-server is disabled: unused, and its aggregated API delayed readiness after a restart.
- k3s specifics to know: `kubernetes.default` is DNATed to the node IP on 6443 (NetworkPolicies
  allow that address), and kube-router rejects denied traffic instead of dropping it.

## Alternatives considered

kind (no built-in LoadBalancer: needs MetalLB or cloud-provider-kind), minikube (heavier VM driver
on macOS, CNI choice for NetworkPolicies), Docker Desktop's Kubernetes (no version pinning, single
global cluster).

## AWS mapping

EKS with managed node groups; see ADR-006.
