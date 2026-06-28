# Customer Onboarding Module Outputs

output "customer_name" {
  value       = var.customer_name
  description = "Customer identifier"
}

output "namespace" {
  value       = var.customer_name
  description = "Kubernetes namespace for the customer"
}

output "n8n_url" {
  value       = "https://${var.customer_name}.${var.domain}"
  description = "n8n instance URL"
}

output "gitops_path" {
  value       = local.customer_path
  description = "Path to generated GitOps manifests"
}

output "storage_container" {
  value       = azurerm_storage_container.customer.name
  description = "Azure storage container for backups"
}

output "db_service" {
  value       = "${var.customer_name}-db-rw.${var.customer_name}.svc.cluster.local"
  description = "PostgreSQL read-write service endpoint"
}

