# Postmortems

Short, blameless write-ups: timeline, impact, root cause, what detected it, what changed.
The two below are real incidents met while building the lab on a laptop, not lab scenarios.

| Date | Incident | Root cause |
|---|---|---|
| 2026-11-17 | [Kafka crash loop after the Phase 2 rollout](2026-11-17-kafka-crashloop-networkpolicy.md) | default-deny egress blocked the broker's startup call to the Kubernetes API |
| 2026-11-17 | [k3s control plane crash after the Phase 3 rollout](2026-11-17-k3s-control-plane-crash.md) | k3s's default SQLite datastore overwhelmed; Grafana under-sized (contributing) |

The lab scenario `dns` (`make break-dns`) has a runbook in
[`docs/runbooks/incident-dns.md`](../runbooks/incident-dns.md); `make restore-dns` prints the
timeline a postmortem starts from.
