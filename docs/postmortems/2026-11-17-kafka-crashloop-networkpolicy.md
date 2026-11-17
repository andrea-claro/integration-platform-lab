# Postmortem: Kafka crash loop after the Phase 2 rollout (NetworkPolicy)

- Date: 2026-11-17 · Duration: ~15 minutes (22:42–22:58 CET) · Severity: lab, pipeline down
- Status: resolved (PR #6)

## Summary

After Phase 2 was merged, the Kafka pod `ipl-dual-role-0` went into CrashLoopBackOff. The bridge
and the API stayed unready because they depend on Kafka. The default-deny policy in `streaming`
blocked the broker's own call to the Kubernetes API at startup.

## Timeline (CET)

| Time | Event |
|---|---|
| 22:42 | PR #5 (Phase 2) merged; Argo CD deploys Strimzi, Kafka, Mosquitto and the services |
| 22:45 | Node container found stopped (cause not investigated at the time); `k3d cluster start ipl` |
| 22:50 | `make status`: Kafka pod `CrashLoopBackOff`, bridge and API `0/1 Running` |
| 22:51 | `kubectl logs --previous`: storage format step fails with `Failed to retrieve Secret ipl-dual-role-0` (`ConnectException`), exit 1 |
| 22:53 | Cause identified: Strimzi brokers read their configuration Secret through the Kubernetes API (`KubernetesSecretConfigProvider`); `allow-kafka-egress` only allowed KRaft and replication traffic |
| 22:54 | PR #6: API egress for the Kafka pod, reviewed and merged within a minute |
| 22:58 | Kafka Ready; `make smoke` all PASS (fresh readings, 401, 429) |

## Root cause

The NetworkPolicies for `streaming` were written from what the operator and the Topic Operator
need. The Kafka pod's own need, reading its Secret through the API at startup, was missed. Strimzi
1.x loads listener certificates and configuration that way rather than from mounted volumes.

## Why it was not caught before merge

The agent's sandbox validates manifests against a real API server (server-side dry-run, Pod
Security, quotas), but pods do not run there, so NetworkPolicies are never enforced. The smoke test
on the real cluster caught it within minutes.

## What went well

- `kubectl logs --previous` showed the exact failing call; the fix was one commented egress rule.
- Default deny did its job: the broker could not do anything that was not declared.

## Actions

| Action | Status |
|---|---|
| API egress rule for the Kafka pod, with a "why" comment and a row in the flow table | done (PR #6) |
| `PodCrashLooping` alert and runbook, with this incident as the worked example | done (Phase 3) |
| `make import` refuses to run when the k3d cluster is stopped (k3d reported success anyway) | done (PR #6) |
| Run the stack with policies enforced in CI (an ephemeral cluster), so this class of error fails before merge | open |
