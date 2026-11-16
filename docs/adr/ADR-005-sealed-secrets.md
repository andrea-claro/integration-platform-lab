# ADR-005: Secrets in Git only as SealedSecrets

- Status: accepted (2026-11-16)
- Context: Phase 1.3

## Context

Everything in the cluster comes from Git through Argo CD, and the repository is public.
Secrets (Telegram bot token, API keys, Grafana and MQTT passwords) must therefore be stored in
Git in a form that is useless without a key that never leaves the cluster.

The project rules exclude Bitnami charts and images, because Bitnami discontinued its free
application catalog in 2025.

## Decision

- Use **Sealed Secrets** (controller 0.41.2, chart 2.22.0) in the `platform` namespace.
- Real values live only in `.env` on the workstation (gitignored, mode 600).
  `make seal` pipes `kubectl create secret --dry-run` into `kubeseal`, so a plain `Secret`
  never touches the disk; only the resulting `SealedSecret` is committed.
- `scripts/check-no-plain-secrets.sh` (in `make lint` and CI) fails on plain `Secret` manifests,
  tracked `.env` files and controller key backups.
- The controller key pair is backed up locally with `make seal-backup` (gitignored `secrets/`)
  and restored by `make bootstrap`, so recreating the cluster does not invalidate the committed
  SealedSecrets.

**Exception to the "no Bitnami" rule.** Sealed Secrets is an open-source project (Apache-2.0)
maintained by Bitnami; its chart (`bitnami.github.io/sealed-secrets`) and controller image
(`docker.io/bitnami/sealed-secrets-controller`) are the project's own official artifacts, free
to pull without an account and actively released. The rule targets the discontinued Bitnami
application catalog, which this is not.

## Consequences

- Simple: one chart, no Argo CD plugin, works offline once the controller key exists.
- Secrets are bound to namespace and name (strict scope): moving a secret means re-sealing it.
- Losing both the cluster and the key backup means re-sealing everything from `.env`.

## Alternatives considered

- **SOPS + age with an Argo CD plugin (KSOPS):** no controller, but needs a custom repo-server
  image or plugin sidecar and key distribution to Argo CD; more moving parts for a lab.
- **External Secrets Operator + a local vault:** closest to the AWS target (Secrets Manager),
  but needs a secret store running locally; planned only as the AWS mapping (ADR-006).

## AWS mapping

AWS Secrets Manager + External Secrets Operator, with KMS for encryption and IRSA / Pod Identity
for access.
