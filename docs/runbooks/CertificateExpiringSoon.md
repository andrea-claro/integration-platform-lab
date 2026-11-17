# CertificateExpiringSoon

**Alert:** a cert-manager Certificate expires in less than 21 days. cert-manager renews 30 days
before expiry (`renewBefore: 720h` on `gateway-tls`), so renewal has been failing for over a week.
Severity: warning.

**Impact:** none yet. If nothing is done, HTTPS through the gateway fails on expiry for every
client, including the public hostnames.

## Diagnose

```bash
kubectl get certificate -A                         # READY, and which one
kubectl -n platform describe certificate gateway-tls
kubectl -n platform get certificaterequest         # failed requests and their message
kubectl get clusterissuer internal-ca -o wide      # issuer Ready?
kubectl -n platform logs deploy/cert-manager --tail=50 | grep -i error
```

| What you see | Likely cause | Fix |
|---|---|---|
| ClusterIssuer `internal-ca` not Ready | CA secret `internal-root-ca` missing or root expired | check `platform-pki` in Argo CD; the root is valid 10 years |
| CertificateRequest denied / failed | issuer reference or DNS names changed in Git | correct `gitops/platform/gateway/certificate.yaml` |
| no CertificateRequest at all | cert-manager controller down | `kubectl -n platform get pods`; [PodCrashLooping](PodCrashLooping.md) |

To force a renewal once the cause is fixed: `cmctl renew -n platform gateway-tls`, or delete the
`gateway-tls` Secret (cert-manager issues a new one; Envoy picks it up without a restart).
