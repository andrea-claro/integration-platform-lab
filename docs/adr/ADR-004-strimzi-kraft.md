# ADR-004: Strimzi Kafka in KRaft mode, single node

- Status: accepted (2026-11-17)
- Context: Phase 2.1

## Context

The integration flow needs a durable log between ingestion (MQTT bridge) and consumers, with
consumer-lag visibility, within ~1 GiB of memory.

## Decision

Strimzi 1.3.1 (API `kafka.strimzi.io/v1`) running Kafka 4.3.2 in KRaft mode: one node with both
controller and broker roles, a 2 Gi persistent volume, topics declared as `KafkaTopic` resources
(auto-creation off), Topic Operator and Kafka Exporter. Plain listener inside the cluster, restricted
by the NetworkPolicy Strimzi generates from `networkPolicyPeers` (bridge and API only).

## Consequences

- Kafka is managed declaratively like everything else; topics are reviewed in pull requests.
- **No redundancy:** replication factor 1, `min.insync.replicas=1`. A broker restart pauses the stream;
  the bridge then stops acknowledging MQTT messages and the broker queues them, so acknowledged data
  is not lost (`acks=all`, idempotent producer, persistent volume).
- Strimzi brokers read their configuration Secret through the Kubernetes API at startup, so the
  Kafka pod needs API egress (found during verification, PR #6).
- Client TLS and authentication (KafkaUser) are not enabled yet: next step.

## Alternatives considered

Plain Apache Kafka image without an operator (no declarative topics, manual config), Redpanda
(lighter, but less representative), a managed service (not free).

## AWS mapping

Amazon MSK (or MSK Serverless): 3 brokers across AZs, IAM or mTLS client authentication, topics
still managed as code.
