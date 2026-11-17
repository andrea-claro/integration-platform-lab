# Incident lab: `dns`, Kafka hostname that does not resolve

**Scenario.** Someone "fixes" the bridge live, with a Kafka bootstrap address copied from the
Strimzi quickstart: namespace `kafka` instead of ours, `streaming`. The name does not resolve, so the
bridge cannot reach Kafka. The change bypasses Git, so Argo CD sees drift. In the lab, self-heal is
paused first, otherwise Argo CD would undo the change within seconds.

```bash
make break-dns      # inject
make restore-dns    # recover through GitOps and print a timeline
```

## 1. Symptom

- Alert **`TelemetryPipelineStalled`** (critical) fires within about 5 minutes
  (`make alertmanager-ui`, or "Firing alerts" on the dashboard).
- The API still answers `200`, but `ts` of the newest reading stops moving: stale data, not an outage.
- Dashboard "Integration Platform overview", **Messages per second**: "published by the simulator"
  still flat at ~2/s, "acknowledged by Kafka" and "consumed by the API" drop to 0. The device side is
  healthy; the break is between the bridge and Kafka. **Bridge → Kafka** shows DOWN; **Backlog**:
  "MQTT messages waiting for Kafka" climbs to the in-flight limit, Kafka lag stays at 0 (nothing new
  to consume).

## 2. Diagnose: follow the evidence

```bash
make status
#  iot-mqtt-kafka-bridge   OutOfSync   Degraded      <- live state differs from Git
#  iot   mqtt-kafka-bridge-...   0/1   Running        <- not ready

kubectl -n iot logs deploy/mqtt-kafka-bridge --tail=20
#  JSON lines from logger "librdkafka", with a msg like:
#  "... Failed to resolve 'ipl-kafka-bootstrap.kafka.svc.cluster.local:9092': Name or service not known"

kubectl -n iot exec deploy/mqtt-kafka-bridge -- python -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/readyz').read())"
#  {"mqtt_connected": true, "kafka_up": false}   <- MQTT fine, Kafka unreachable
```

Is it DNS, the network, or Kafka? Check each layer from inside the bridge pod:

```bash
# DNS: the configured name vs the real Service
kubectl -n iot exec deploy/mqtt-kafka-bridge -- python -c \
  "import socket;print(socket.gethostbyname('ipl-kafka-bootstrap.streaming.svc.cluster.local'))"   # resolves
kubectl -n iot exec deploy/mqtt-kafka-bridge -- python -c \
  "import socket;print(socket.gethostbyname('ipl-kafka-bootstrap.kafka.svc.cluster.local'))"       # gaierror
kubectl get ns kafka                                  # NotFound: the name points at a namespace that does not exist

# Kafka itself is fine
kubectl -n streaming get kafka ipl                    # READY True
```

What changed, and who changed it: compare the live object with Git.

```bash
kubectl -n iot get deploy mqtt-kafka-bridge \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_BOOTSTRAP_SERVERS")].value}'
grep -n KAFKA_BOOTSTRAP gitops/iot/mqtt-kafka-bridge/mqtt-kafka-bridge.yaml
kubectl -n iot get deploy mqtt-kafka-bridge --show-managed-fields -o yaml | grep -B1 -A3 'manager: kubectl-set'
#  the env field was last written by "kubectl-set": a manual change, not Argo CD
```

The Argo CD UI (`make argocd-ui`) shows the same thing as a diff on the Deployment.

## 3. Root cause

The bootstrap address was changed live to a hostname in a namespace that does not exist. DNS returns
NXDOMAIN, librdkafka cannot bootstrap, the bridge reports `kafka_up: false` and stops acknowledging
MQTT messages. Contributing factor: self-heal was off for this application. In the lab, that is the
injection. In real life, it is the reason drift can survive.

## 4. Fix

Put Git's desired state back. Do not edit the Deployment by hand again.

```bash
make restore-dns
```

That resumes Argo CD self-heal. Argo CD re-applies the value from Git and the bridge restarts with
the right address. In real life, the fix is either a revert of the bad commit or, for a live change
like this one, a sync from Git.

## 5. Verify

- `make status`: `iot-mqtt-kafka-bridge` Synced/Healthy, no pod unready.
- `restore-dns` prints the timeline (injected, alert fired, restore, recovered) and compares the
  messages published during the outage with those delivered to Kafka. Delivered ≥ published means
  nothing was lost: Mosquitto queued the messages for the bridge's persistent session, and the
  bridge acknowledged each one only after Kafka accepted it.
- The alert resolves within a few minutes. `make smoke` passes.

## Why it is worth practising

- The failure is visible at the right layer: a **symptom alert** (data not flowing), not a cause
  alert ("DNS is broken").
- Readiness tells which dependency is broken (`mqtt_connected` vs `kafka_up`).
- GitOps turns "what changed?" into a diff, and recovery into a sync.
- The delivery guarantee holds through the outage.
