variable "kubeconfig_path" {
  description = "Path to the kubeconfig that contains the k3d context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kube context of the local cluster (k3d prefixes the cluster name with k3d-)."
  type        = string
  default     = "k3d-ipl"

  validation {
    condition     = startswith(var.kube_context, "k3d-")
    error_message = "Bootstrap only targets the local k3d cluster (context must start with k3d-)."
  }
}

variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (10.18.0 = Argo CD v3.6.1)."
  type        = string
  default     = "10.18.0"
}

variable "argocd_apps_chart_version" {
  description = "Pinned version of the argocd-apps Helm chart that creates the root Application."
  type        = string
  default     = "2.0.8"
}

variable "gitops_repo_url" {
  description = "Public Git repository Argo CD syncs from."
  type        = string
  default     = "https://github.com/andrea-claro/integration-platform-lab.git"
}

variable "gitops_revision" {
  description = "Branch, tag or commit the root Application tracks."
  type        = string
  default     = "main"
}

variable "root_app_path" {
  description = "Path of the app-of-apps directory inside the repository."
  type        = string
  default     = "gitops/root"
}
