# ADR-002: Gateway API with Envoy Gateway instead of ingress-nginx

- Status: accepted (2026-11-16)
- Context: Phase 1.1, 2.6

## Context

The platform needs one HTTPS entry point with TLS from an internal CA, per-route rate limiting and
API-key authentication. ingress-nginx was retired in March 2026, and API management features on
Ingress live in controller-specific annotations.

## Decision

Gateway API (v1.6) implemented by Envoy Gateway v1.9.3: one `Gateway` (`platform/public`, HTTPS
443) that only namespaces labelled `gateway-access=true` may attach routes to; `HTTPRoute`s per
service; Envoy Gateway policies for traffic (`BackendTrafficPolicy`: local rate limits) and security
(`SecurityPolicy`: API keys from a SealedSecret).

## Consequences

- Role split matches the domains: the platform owns the Gateway and its certificate, the `apps`
  domain owns its routes and policies.
- API management without a separate product: 401 for a missing key and 429 over the limit come from
  the gateway, before the service.
- Policy features differ by Envoy Gateway version: versions are pinned and the CRD schemas of the
  pinned version were checked before writing policies (filter order verified in the v1.9.3 source).
- Envoy listens on 10443 for the 443 listener (ports below 1024 shifted by 10 000), which the
  NetworkPolicies reflect.

## Alternatives considered

Traefik (bundled with k3s, but CRD-based middleware instead of the standard API), Istio ingress
gateway (too heavy for the budget), Kong (API management, but another control plane).

## AWS mapping

The same Gateway and HTTPRoute manifests run with Envoy Gateway on EKS behind an NLB, or with the
AWS Load Balancer Controller's Gateway API support.
