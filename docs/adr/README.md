# Architecture Decision Records

One short record per decision (PLAN.md §3): context, decision, consequences, alternatives, AWS mapping.

- [ADR-001](ADR-001-k3d.md) k3d (k3s in Docker) as the local cluster
- [ADR-002](ADR-002-gateway-api.md) Gateway API with Envoy Gateway instead of ingress-nginx
- [ADR-003](ADR-003-gitops.md) Argo CD app-of-apps; Helm for third-party charts, Kustomize for our own manifests
- [ADR-004](ADR-004-strimzi-kraft.md) Strimzi Kafka in KRaft mode, single node
- [ADR-005](ADR-005-sealed-secrets.md) Secrets in Git only as SealedSecrets
- [ADR-006](ADR-006-aws-mapping.md) Local ↔ AWS mapping
