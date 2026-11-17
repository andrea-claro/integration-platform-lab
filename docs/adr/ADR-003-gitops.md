# ADR-003: Argo CD app-of-apps; Helm for third-party charts, Kustomize for our manifests

- Status: accepted (2026-11-15)
- Context: Phase 0.4

## Context

GitOps is the only deployment path (CLAUDE.md). Components belong to different domains (platform,
streaming, iot, apps, observability) that should not be able to change each other's resources.

## Decision

- OpenTofu (Helm provider) installs Argo CD v3.6 and one `root` Application; nothing else is applied
  by hand.
- `gitops/root` holds one Application per component (app-of-apps), ordered with sync waves.
- Third-party software from its upstream Helm chart (pinned version, values inline in the
  Application); our own manifests with Kustomize.
- One `AppProject` per domain. Only `platform` may create cluster-scoped kinds, from an explicit
  allow list. Operators that ship CRDs (Strimzi, kube-prometheus-stack) are therefore installed
  through `platform` into their domain namespace. Domain projects cannot touch NetworkPolicies,
  ResourceQuotas or LimitRanges.

## Consequences

- Every change is a pull request; Argo CD syncs from the public repository about once a minute.
- Drift is visible and self-healed. The incident lab pauses self-heal on purpose to inject faults
  and resumes it to recover.
- CRDs from charts need `ServerSideApply=true` (size limit of client-side apply).

## Alternatives considered

Flux (equally valid; Argo CD's UI makes drift and diffs easier to show), ApplicationSets (fewer
files, but less explicit for a dozen components).

## AWS mapping

Unchanged on EKS: Argo CD in the cluster, the root Application created by Terraform.
