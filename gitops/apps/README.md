# apps

Telemetry API (PLAN 2.5–2.6), Application `apps-telemetry-api`, project `apps`.

| File | What |
|---|---|
| `telemetry-api.yaml` | Deployment (one replica: in-memory store), Service `telemetry-api:80` |
| `routes.yaml` | HTTPRoutes on the shared Gateway, host `api.ipl.localhost` (locally `https://api.ipl.localhost:8443`) |
| `policies.yaml` | Envoy Gateway `SecurityPolicy` (API key) and `BackendTrafficPolicy` (local rate limits) |
| `sealedsecret-api-keys.yaml` | API keys per client id (`demo`, `admin`), from `make seal` |

| Path | Auth | Rate limit (per minute) |
|---|---|---|
| `/v1/*` | `x-api-key` header, checked by the gateway | `demo` key 20, everything else 300 |
| `/`, `/docs`, `/openapi.json` | none (public docs, "Authorize" with the demo key) | 300 |
| `/healthz`, `/readyz`, `/metrics` | not routed (404), cluster-internal only | — |

The gateway rejects a missing or wrong key with 401 before the request reaches the service,
removes the key from the forwarded request and adds `x-client-id: <client>` instead (Envoy
overwrites any value the client sent). Over the limit: 429 with `x-ratelimit-*` headers.

```bash
# keys come from the decrypted Secret in the cluster
KEY=$(kubectl -n apps get secret telemetry-api-keys -o jsonpath='{.data.demo}' | base64 -d)
kubectl -n platform get secret internal-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ipl-ca.crt
curl --cacert /tmp/ipl-ca.crt -H "x-api-key: $KEY" https://api.ipl.localhost:8443/v1/readings/latest
```
