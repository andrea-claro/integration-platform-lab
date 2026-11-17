# PodCrashLooping

**Alert:** a container has been in `CrashLoopBackOff` for 5 minutes (kube-state-metrics).
Severity: warning.

## Diagnose

```bash
kubectl -n <namespace> describe pod <pod> | sed -n '/Last State/,/Ready:/p;/Events:/,$p'
kubectl -n <namespace> logs <pod> -c <container> --previous --tail=80
```

| Last State / log | Likely cause | Fix |
|---|---|---|
| `OOMKilled`, exit 137 | memory limit too low | raise the limit in Git (stay within PLAN §7) |
| exit 1 right after start, connection errors | a dependency is unreachable: DNS, NetworkPolicy, another service | follow the error; NetworkPolicies are in `gitops/platform/guardrails` |
| liveness probe failed | slow start on a busy laptop | check CPU; raise `initialDelaySeconds` only with a reason |
| configuration error | bad value in Git | fix and let Argo CD sync |

**Real example (Phase 2 verification):** the Kafka pod exited 1 with
`Failed to retrieve Secret ipl-dual-role-0` because the default-deny policy in `streaming` blocked
its call to the Kubernetes API. Fixed with an explicit egress rule (PR #6).
