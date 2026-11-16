# helm provider v3 syntax: `kubernetes` is an attribute (object), not a block.
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
