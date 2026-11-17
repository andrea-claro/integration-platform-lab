# incidents

Incident lab (PLAN 4). One folder per scenario with `inject.sh` and `restore.sh`; `make incidents`
lists them, `make break-<name>` / `make restore-<name>` run them. Shared helpers: `lib.sh`.

Rules of the lab:

- Faults are **live drift** on a resource Argo CD manages. Self-heal is paused for that application
  (and for `root`, which would otherwise restore the application's sync policy from Git). This is
  the only place where manual changes to the cluster are allowed (CLAUDE.md).
- **Recovery always goes through GitOps.** `restore.sh` resumes self-heal and Argo CD puts the Git
  state back. Nothing is fixed by hand.
- `restore.sh` prints a timeline (injected, alert fired, restore, recovered) for the postmortem.

Status: the `dns` scenario is checked by shellcheck and CI but has not been run end to end yet: the
laptop cluster was retired before it (see [evidence](../docs/evidence/)).

| Scenario | Fault | Detected by | Runbook | Postmortem |
|---|---|---|---|---|
| `dns` | bridge points at a Kafka hostname in a namespace that does not exist | `TelemetryPipelineStalled` | [incident-dns.md](../docs/runbooks/incident-dns.md) | [docs/postmortems](../docs/postmortems/) |

Cut for time (PLAN §6), natural next ones: `cert` (gateway certificate expiring), `netpol` (missing
allow rule), `oom` (memory limit too low). The Phase 2 Kafka crash loop is a real `netpol` case,
written up in [PodCrashLooping](../docs/runbooks/PodCrashLooping.md).
