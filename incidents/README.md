# incidents

Incident lab (Phase 4). One folder per scenario with `inject.sh`, `restore.sh` and a README;
`make break-<name>` / `make restore-<name>` call them. Recovery always goes through Git and Argo CD.

MVP scenarios: `cert` (gateway certificate expiring/expired), `dns` (bridge pointed at a wrong
Kafka hostname). Later: `netpol`, `oom`.
