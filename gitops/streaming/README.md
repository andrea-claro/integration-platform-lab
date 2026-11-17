# streaming

Kafka on Strimzi (PLAN 2.1, ADR-004).

| What | Where | Application / project |
|---|---|---|
| Strimzi operator 1.3.1 (CRDs, cluster RBAC, operator in `streaming`) | `gitops/root/strimzi.yaml` (Helm, OCI chart) | `strimzi` / `platform` |
| Kafka cluster `ipl`: Kafka 4.3.2, KRaft, one dual-role node, 2 Gi volume | `kafka/kafka.yaml` | `streaming-kafka` / `streaming` |
| Topics `telemetry.raw` (3 partitions, 1 h) and `telemetry.dlq` (1 partition, 24 h) | `kafka/topics.yaml` | same |
| Topic Operator, Kafka Exporter (topic offsets, consumer lag) | `kafka/kafka.yaml` | same |

The operator is installed through the `platform` project because its chart ships CRDs and
ClusterRoles; the `streaming` project only holds the Kafka resources and cannot create
cluster-scoped objects. Every pod Strimzi creates gets a security context that passes the
`restricted` Pod Security Standard (`STRIMZI_POD_SECURITY_PROVIDER_CLASS=restricted`).

**Clients.** Bootstrap `ipl-kafka-bootstrap.streaming.svc:9092` (plain, cluster-internal). The
NetworkPolicy that Strimzi generates from the listener's `networkPolicyPeers` admits only the bridge
(producer) and the telemetry API (consumer) on 9092. Client TLS and authentication (KafkaUser) are
a planned hardening step.

**Single-node trade-offs.** Replication factor 1, `min.insync.replicas=1`: no redundancy. A broker
restart pauses the stream (the bridge stops acknowledging MQTT and the broker queues), but nothing
acknowledged is lost (persistent volume, `acks=all`). Topics exist only as `KafkaTopic` resources
(`auto.create.topics.enable=false`).

```bash
kubectl -n streaming get kafka,kafkanodepool,kafkatopic
kubectl -n streaming exec ipl-dual-role-0 -- bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group telemetry-api
```
