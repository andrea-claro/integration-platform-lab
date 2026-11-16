output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "argocd_version" {
  description = "Argo CD application version installed by the chart."
  value       = helm_release.argocd.metadata.app_version
}

output "root_app_source" {
  value = "${var.gitops_repo_url}@${var.gitops_revision}:${var.root_app_path}"
}

output "next_steps" {
  value = <<-EOT
    Initial admin password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
    UI (local only):
      kubectl -n argocd port-forward svc/argocd-server 8080:80   ->  http://localhost:8080
  EOT
}
