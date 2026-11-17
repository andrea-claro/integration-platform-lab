# observability

Lean monitoring (PLAN 3, scope update in §6). Two Applications:

| Application / project | What |
|---|---|
| `kube-prometheus-stack` / `platform` (`gitops/root/kube-prometheus-stack.yaml`) | Prometheus Operator, Prometheus (2-day retention), Alertmanager, Grafana, kube-state-metrics. No node-exporter, no k3s control-plane scraping, none of the chart's default rules or dashboards. |
| `observability-config` / `observability` (this folder) | what to scrape (`monitors.yaml`), alert rules (`rules/`), the dashboard (`dashboards/`), the Grafana admin SealedSecret |

Prometheus only picks up monitors and rules from this namespace, so a domain project cannot add
scrape targets or alerts on its own. Requests: about 650 MiB in total.

## Scraped

| Target | Metrics used |
|---|---|
| device-simulator, mqtt-kafka-bridge, telemetry-api (`/metrics` on 8080) | messages published / produced / consumed, Kafka reachability, pending messages, API requests and latency, end-to-end latency |
| Kafka Exporter (Strimzi) | `kafka_consumergroup_lag`, topic offsets |
| cert-manager controller | certificate expiry |
| kube-state-metrics | pod readiness, restarts, `CrashLoopBackOff` |

## Alerts

Every rule has a runbook in [`docs/runbooks/`](../../docs/runbooks/) (linked by `runbook_url`) and a
promtool unit test in [`tests/promtool/`](../../tests/promtool/) (`make test-rules`).

| Alert | Fires when | Severity |
|---|---|---|
| `TelemetryPipelineStalled` | no record reached Kafka for 3 minutes (symptom: stale data) | critical |
| `KafkaConsumerLagHigh` | the API's consumer group is more than 500 records behind for 5 minutes | warning |
| `CertificateExpiringSoon` | a certificate expires in less than 21 days (renewal at 30 days failed) | warning |
| `PodCrashLooping` | a container has been in `CrashLoopBackOff` for 5 minutes | warning |
| `TargetDown` | a scrape target has been down for 5 minutes | warning |

No external receiver: alerts are read in Alertmanager (`make alertmanager-ui`), Prometheus
(`make prometheus-ui`, Alerts tab) and the dashboard's "Firing alerts" panel.

## Dashboard

"Integration Platform overview" (`make grafana-ui`, http://localhost:3000, user `admin`, password
`GRAFANA_ADMIN_PASSWORD` from `.env`): health at a glance (firing alerts, Kafka reachability,
devices, end-to-end latency, pods not ready, certificate expiry), message rates through the
pipeline, Kafka lag and bridge backlog, API requests and latency, restarts and scrape targets.
Edit the JSON in `dashboards/`, not in the UI: the dashboard is read-only and reloaded from Git.
