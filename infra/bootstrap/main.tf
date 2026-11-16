# Bootstrap (PLAN.md task 0.4): the only Terraform-managed objects in the cluster.
# Everything else is delivered by Argo CD from gitops/.

locals {
  argo_helm_repo = "https://argoproj.github.io/argo-helm"
  namespace      = "argocd"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = local.namespace
  create_namespace = true
  repository       = local.argo_helm_repo
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [file("${path.module}/values/argocd.yaml")]

  wait    = true
  timeout = 600
}

# Root Application of the app-of-apps pattern (ADR-003).
resource "helm_release" "root_app" {
  name       = "root-app"
  namespace  = local.namespace
  repository = local.argo_helm_repo
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace = local.namespace
        project   = "default"
        # Deleting the root app cascades to the child apps (clean `tofu destroy`).
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = var.root_app_path
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = local.namespace
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          retry = {
            limit = 5
            backoff = {
              duration    = "10s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
