# KafkaConsumerLagHigh

**Alert:** consumer group `telemetry-api` has more than 500 records left on `telemetry.raw` for
5 minutes (Kafka Exporter `kafka_consumergroup_lag`). Severity: warning.

**Impact:** about 2 records/s are produced, so 500 records means the API answers several minutes
behind the devices. Data is not lost (1 h retention), only late.

## Diagnose

```bash
kubectl -n apps get pods -l app.kubernetes.io/name=telemetry-api
kubectl -n apps logs deploy/telemetry-api --tail=30
kubectl -n streaming exec ipl-dual-role-0 -- bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group telemetry-api
#  CONSUMER-ID empty -> nobody is consuming; LAG growing on one partition -> stuck consumer
```

| What you see | Likely cause | Fix |
|---|---|---|
| no members in the group | API pod down or not ready | [PodCrashLooping](PodCrashLooping.md) |
| members present, lag keeps growing | consumer stuck or too slow (CPU throttling, errors in logs) | restart through Git (bump an annotation) or fix the error |
| lag spiked once, now shrinking | catch-up after an outage (bridge drained the MQTT queue) | nothing: wait for it to fall below 500 |

The API runs as one replica on purpose (in-memory store), so scaling out is not the fix.
