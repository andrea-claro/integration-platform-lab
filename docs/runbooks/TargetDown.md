# TargetDown

**Alert:** Prometheus has not been able to scrape a target for 5 minutes (`up == 0`).
Severity: warning.

**Impact:** the target's metrics are missing, so alerts based on them go blind (for example
`TelemetryPipelineStalled` fires when the bridge cannot be scraped).

## Diagnose

```bash
make prometheus-ui        # http://localhost:9090/targets: the error column says why
kubectl -n <namespace> get pod <pod> -o wide
```

| Scrape error | Likely cause | Fix |
|---|---|---|
| `connection refused` (fast) | pod not listening, or kube-router rejected the connection | is the pod ready? Then check the NetworkPolicies of both namespaces |
| `context deadline exceeded` | pod overloaded, or traffic dropped | pod CPU/memory, then NetworkPolicies |
| target missing entirely | pod gone or labels changed | the PodMonitor selectors in `gitops/observability/monitors.yaml` |

Prometheus may scrape any pod of a domain namespace (`allow-prometheus-scrape` in each namespace)
and has egress to those namespaces (`gitops/platform/guardrails/namespaces/observability`). A new
namespace needs both.
