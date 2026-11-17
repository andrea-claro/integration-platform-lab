# TelemetryPipelineStalled

**Alert:** no record acknowledged by Kafka for at least 3 minutes (`bridge_kafka_messages_produced_total`
flat, or the bridge not scraped at all). Severity: critical.

**Impact:** the API keeps answering, but with readings that get older every minute. MQTT messages
queue in Mosquitto (bridge's persistent session, up to 10 000) and are delivered once the cause is
fixed: nothing acknowledged is lost unless the queue overflows.

## Diagnose: walk the pipeline from the device to Kafka

```bash
make status                                                     # anything not Synced/Healthy?
kubectl -n iot get pods                                         # simulator, broker, bridge running?
kubectl -n iot logs deploy/mqtt-kafka-bridge --tail=30          # JSON logs: look at "error"
kubectl -n iot exec deploy/mqtt-kafka-bridge -- python -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/readyz').read())"
#  {"mqtt_connected": ..., "kafka_up": ...} tells which side is broken
kubectl -n streaming get kafka ipl                              # READY True?
kubectl -n streaming get pods                                   # broker, operators
```

In Grafana ("Integration Platform overview"): simulator published vs bridge produced. Published
still flowing and produced at zero → the bridge cannot reach Kafka. Both at zero → MQTT side.

| What you see | Likely cause | Next step |
|---|---|---|
| `kafka_up: false`, logs `Failed to resolve` / `Name or service not known` | wrong `KAFKA_BOOTSTRAP_SERVERS` | walkthrough: [incident-dns.md](incident-dns.md) |
| `kafka_up: false`, connection refused / timeouts | Kafka down or a NetworkPolicy change | `kubectl -n streaming describe pod ipl-dual-role-0`, [PodCrashLooping](PodCrashLooping.md) |
| `mqtt_connected: false`, `not authorised` | MQTT credentials out of sync with the broker's password file | `make seal`, commit the SealedSecrets |
| bridge pod missing or not ready | rollout or crash | [PodCrashLooping](PodCrashLooping.md), [TargetDown](TargetDown.md) |

## Fix

Fix the cause in Git and let Argo CD sync; no manual `kubectl edit` (self-heal would revert it,
and the change would not survive a rebuild). Recovery is automatic once Kafka is reachable: the
bridge drains the broker queue and the alert resolves within a few minutes.
