# Postmortem: k3s control plane crash after the Phase 3 rollout (SQLite datastore)

- Date: 2026-11-17 · Duration: cluster unusable from ~23:19 CET until it was retired · Severity: lab, whole cluster
- Status: mitigated in Git (embedded etcd, Grafana limits); not re-verified on a rebuilt cluster

## Summary

Minutes after the monitoring stack was deployed, the Kubernetes API started timing out. Then k3s
exited with a fatal error from its default SQLite datastore. Docker restarted the node, but the API
stayed overloaded. Separately, Grafana was OOM-killed at its 256 Mi limit. The decision that
followed: share the lab as a repository, with k3s on embedded etcd, instead of keeping a live
cluster on the laptop.

## Timeline (CET)

| Time | Event |
|---|---|
| 23:15 | PR #7 (Phase 3) merged; Argo CD starts applying kube-prometheus-stack (CRDs and ~36 objects) |
| 23:19 | API server requests start exceeding their deadline (`FinishRequest: post-timeout activity ... context deadline exceeded`) |
| ~23:2x | Grafana OOM-killed at its 256 Mi limit: the kernel kills `grafana` and a dozen `gpx_grafana-*` plugin processes |
| 23:26:27 | k3s exits: `level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"` |
| 23:26:40 | Docker restarts the node container (restart policy); the API comes back slowly (aggregated metrics API unavailable, controllers resyncing) |
| 23:29 | `make status` and `make break-dns`: `Unable to connect to the server: EOF` |
| 23:31 | `docker inspect`: `oom=true restarts=1`; looks like the node ran out of memory |
| 23:33 | Kernel log: only `Memory cgroup out of memory` for Grafana, a pod-level limit. `docker stats`: node at 4 GiB of 16 GiB, so not the VM |
| 23:35 | k3s log shows the real failure: the SQLite (kine) transaction error |
| 23:34–23:47 | PR #10: Grafana limits; embedded etcd and metrics-server off; decision to share the repo only |

## Root causes

1. **Datastore.** On a single server, k3s defaults to SQLite through kine. By Phase 3 the cluster
   ran a dozen controllers renewing leader-election leases (cert-manager ×3, Envoy Gateway,
   Strimzi and its Topic Operator, Prometheus Operator, Sealed Secrets, Argo CD), and Argo CD was
   applying large CRDs with server-side apply. Writes outpaced SQLite on Docker Desktop's disk;
   requests timed out until a transaction failed and k3s exited.
2. **Grafana limit (contributing).** Grafana 13 runs each bundled datasource plugin as a separate
   process; 256 Mi was not enough to start. The crash loop added churn but did not, on its own,
   take the control plane down.

## What misled the investigation

Docker's `OOMKilled` flag on the node container was `true`, which pointed at the node running out of
memory. The flag counts OOM kills anywhere in the container's cgroup tree, including pods inside
it. The kernel log (`dmesg`) named the process (Grafana) and the kind of kill (cgroup limit, not
global). `docker stats` ruled out VM memory. Lesson: read the kernel log before changing limits.

## What went well

- Everything is declarative: retiring the cluster loses nothing, and `make down && make cluster &&
  make bootstrap` rebuilds it from Git (the Sealed Secrets key backup is restored by bootstrap).
- Each hypothesis was checked with a measurement before a change was made.

## Actions

| Action | Status |
|---|---|
| k3s with embedded etcd (`--cluster-init`); metrics-server disabled | done (this repo, `cluster/k3d.yaml`) |
| Grafana request 192 Mi, limit 512 Mi | done (PR #10) |
| Rebuild on etcd and re-run `make smoke` (Phases 1–3) and `make break-dns` / `restore-dns` | open |
| Dead man's switch: an always-firing alert delivered outside the cluster, since in-cluster alerting dies with the control plane | open |
| Count the control plane's datastore in the resource budget (PLAN §7) | noted |
