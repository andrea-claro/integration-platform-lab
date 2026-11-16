terraform {
  # Works with OpenTofu (preferred) and Terraform.
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
  }

  # Local state on purpose: this stack only bootstraps a disposable local
  # cluster. The state file is gitignored and holds no secrets (no secret
  # values are passed to the Helm releases).
}
