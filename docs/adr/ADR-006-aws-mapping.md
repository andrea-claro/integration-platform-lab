# ADR-006: Local ↔ AWS mapping

- Status: accepted (2026-11-17)
- Context: PLAN §3

## Context

The lab runs locally at zero cost, but the target environment for this kind of platform is
usually AWS/EKS. Each local choice should have a clear production counterpart, so the lab shows
the concepts rather than a local-only setup.

## Decision

| Local | AWS / EKS | Notes |
|---|---|---|
| k3d (k3s in Docker), one node | EKS, managed node groups across AZs | ADR-001 |
| k3s service load balancer | AWS Load Balancer Controller (NLB) | Gateway API on both |
| Envoy Gateway | Envoy Gateway on EKS, or the AWS LB Controller's Gateway API | same Gateway/HTTPRoute manifests (ADR-002) |
| cert-manager with an internal CA | ACM / ACM Private CA (or cert-manager with ACM PCA issuer) | expiry alert unchanged |
| CoreDNS | Route 53 private hosted zones + CoreDNS | the `dns` incident applies as is |
| ServiceAccount per workload, no API rights | IRSA / EKS Pod Identity | least privilege per workload |
| Sealed Secrets | AWS Secrets Manager + External Secrets Operator, KMS | ADR-005 |
| NetworkPolicies (default deny) | VPC design, security groups for pods, PrivateLink / VPC endpoints | |
| Strimzi Kafka, one node | Amazon MSK, 3 brokers, IAM/mTLS auth | ADR-004 |
| Mosquitto | AWS IoT Core (MQTT, per-device certificates) | |
| kube-prometheus-stack | Amazon Managed Prometheus + Managed Grafana, or the same stack | rules and dashboards unchanged |
| k3d loopback port mapping (no public exposure) | public NLB/ALB, or CloudFront + WAF | |
| GitHub Actions → GHCR | GitHub Actions (OIDC) → ECR | |

## Consequences

The manifests that matter most (Gateway API, Argo CD applications, alert rules, dashboards) carry
over unchanged; what changes is the infrastructure underneath. A validate-only Terraform target for
EKS (`infra/envs/aws`) is listed as a next step.
