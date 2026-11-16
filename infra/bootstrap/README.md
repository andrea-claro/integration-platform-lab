# infra/bootstrap

Terraform/OpenTofu stack that installs the only things not delivered by GitOps:

1. **Argo CD** (`argo-cd` chart 10.18.0, Argo CD v3.6.1) in namespace `argocd`.
2. The **root Application** (`argocd-apps` chart 2.0.8) pointing at `gitops/root`
   (app-of-apps, ADR-003).

Run it through the Makefile, which reads the repository URL from `.env`:

```bash
make cluster      # k3d cluster "ipl" (context k3d-ipl)
make bootstrap    # tofu init + apply in this folder
make status
```

Notes

- `kube_context` must start with `k3d-`: the stack refuses to target any other cluster.
- State is local and gitignored. No secret values are passed to the releases; the Argo CD
  admin password is generated in the cluster (`argocd-initial-admin-secret`).
- Use `TF=terraform make bootstrap` to run with Terraform instead of OpenTofu.
