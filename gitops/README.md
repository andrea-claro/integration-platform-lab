# gitops

Everything that runs in the cluster comes from this folder through Argo CD (app-of-apps).

| Folder | Contents | Phase |
|---|---|---|
| `root/` | Child `Application` manifests (one per component) | 0 → |
| `platform/` | Namespaces, Envoy Gateway, cert-manager, Sealed Secrets, RBAC, NetworkPolicies, quotas | 0–1 |
| `streaming/` | Strimzi operator, Kafka cluster (KRaft), topics | 2 |
| `iot/` | Mosquitto, device-simulator, mqtt-kafka-bridge | 2 |
| `apps/` | telemetry-api, HTTPRoute, rate limit, API-key auth | 2 |
| `observability/` | kube-prometheus-stack values, dashboards, alert rules | 3 |

Rules: Helm for third-party charts (pinned versions), Kustomize for our own manifests,
secrets only as `SealedSecret` (`make seal`), no manual `kubectl apply`.
