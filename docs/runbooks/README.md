# Runbooks

One runbook per alert and incident scenario: symptom → alert → diagnosis commands → root cause → fix.
Every PrometheusRule links here through its `runbook_url` annotation; `make test-rules` fails if an
alert has no runbook.

| Alert | Runbook |
|---|---|
| `TelemetryPipelineStalled` | [TelemetryPipelineStalled.md](TelemetryPipelineStalled.md) |
| `KafkaConsumerLagHigh` | [KafkaConsumerLagHigh.md](KafkaConsumerLagHigh.md) |
| `CertificateExpiringSoon` | [CertificateExpiringSoon.md](CertificateExpiringSoon.md) |
| `PodCrashLooping` | [PodCrashLooping.md](PodCrashLooping.md) |
| `TargetDown` | [TargetDown.md](TargetDown.md) |
