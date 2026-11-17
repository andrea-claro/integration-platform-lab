# Evidence

What was verified where. The lab is shared as a repository, so this folder keeps the output from
the real cluster for reviewers who do not run it themselves.

| Phase | In the agent's sandbox (every PR) | On the real cluster (k3d on a MacBook Pro) |
|---|---|---|
| 0 Foundations | lint, `tofu validate` | `make cluster && make bootstrap`: Argo CD and root app Healthy |
| 1 Gateway, PKI, guardrails | server-side dry-run against the real CRDs, Pod Security, quotas | `make smoke`: all PASS, including the NetworkPolicy block and `kubectl auth can-i` checks |
| 2 Kafka, MQTT, services, API management | unit tests (63), dry-run, Mosquitto config with the real image | `make smoke`: all PASS: fresh data end to end, 401, 429 ([output](2026-11-17-phase-1-2-smoke.txt)) |
| 3 Observability | promtool tests with a mutation check, dry-run of the rendered chart | deployed; the cluster then crashed on its SQLite datastore ([postmortem](../postmortems/2026-11-17-k3s-control-plane-crash.md)); re-run on etcd open |
| 4 Incident lab (`dns`) | shellcheck, lint | not yet run (needs a stable cluster) |
| 5 CI | `checks` and `images` workflows green on GitHub | — |

The real cluster also produced the two incidents in [`docs/postmortems`](../postmortems/): the
default-deny policy blocking Kafka's startup, and the k3s datastore crash.
