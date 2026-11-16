# Guardrails

Applied to every domain namespace by the `platform-guardrails` Application (project `platform`).
Domain projects (`streaming`, `iot`, `apps`, `observability`) cannot create or change
NetworkPolicies, ResourceQuotas or LimitRanges.

## Network: default deny, explicit allows

Enforced by the kube-router policy controller embedded in k3s. Traffic that originates on the
node itself (kubelet probes, API server → admission webhooks) is always accepted by kube-router.

| From | To | Port | Why |
|---|---|---|---|
| every pod | CoreDNS (`kube-system`) | 53 UDP/TCP | name resolution |
| Prometheus (`observability`) | every pod | any | metrics scraping (Phase 3) |
| controllers in `platform` | Kubernetes API (node IP) | 6443 | watch and update resources |
| anyone | Envoy proxies (`platform`) | 10443 | HTTPS listener; outside the cluster only via `127.0.0.1:8443` and the tunnel |
| Envoy proxies | namespaces with `gateway-access=true` (`apps`, `observability`) | any | route traffic to backends |
| Envoy proxies | Envoy Gateway controller | 18000 | xDS configuration |
| Envoy proxies (`platform`) | every pod in `apps` | any | routed requests |

Everything else is dropped, for example `iot` → `apps` (checked by `tests/smoke/phase1-security.sh`).
Rules for Kafka, Mosquitto and the monitoring stack arrive with those workloads (Phases 2–3).
`argocd` and `kube-system` are not restricted: Argo CD needs GitHub and the chart registries.

## Resources

| Namespace | requests.cpu | requests.memory | limits.memory | pods | Sized for (PLAN §7) |
|---|---|---|---|---|---|
| platform | 1 | 768Mi | 4Gi | 20 | Envoy Gateway + proxy, cert-manager, Sealed Secrets |
| streaming | 1 | 2Gi | 4Gi | 15 | Kafka broker, Strimzi, Kafka Exporter |
| iot | 500m | 512Mi | 1536Mi | 10 | Mosquitto, simulator, bridge |
| apps | 500m | 512Mi | 1536Mi | 10 | telemetry-api |
| observability | 1 | 2Gi | 4Gi | 20 | Prometheus, Alertmanager, Grafana |

CPU is requested but never limited (limits cause throttling on a laptop). The LimitRange gives
containers without explicit resources a default (10m / 64Mi request, 256Mi limit, 2Gi max).
