## Infrastructure Outputs

output "key_vault_name" {
  value = azurerm_key_vault.cloudlab_vault.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.cloudlab_vault.vault_uri
}

output "aks_keyvault_secrets_provider_client_id" {
  value       = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id
  description = "AKS Key Vault Secrets Provider Client ID for use in SecretProviderClass"
}

output "gitops_identity_reminder" {
  value = <<-EOT
    IMPORTANT: Update the AKS identity in GitOps SecretProviderClasses!

    If you recreated the AKS cluster, update this identity ID in:
    - monitoring/controllers/production/kube-prometheus-stack/kustomization.yaml

    Current AKS identity: ${azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id}
  EOT
  description = "Reminder to update GitOps SecretProviderClass identity"
}

output "storage_account_name" {
  value       = azurerm_storage_account.cnpg_backups.name
  description = "Storage account for CNPG backups"
}

output "grafana_admin_password" {
  value       = random_password.grafana_admin.result
  sensitive   = true
  description = "Grafana admin password (stored in Key Vault as grafana-admin-password)"
}

## Customer Outputs

output "customer_urls" {
  value = {
    for name, customer in module.customer : name => customer.n8n_url
  }
  description = "n8n URLs for all customers"
}

output "customer_namespaces" {
  value = {
    for name, customer in module.customer : name => customer.namespace
  }
  description = "Kubernetes namespaces for all customers"
}

output "customer_gitops_paths" {
  value = {
    for name, customer in module.customer : name => customer.gitops_path
  }
  description = "GitOps manifest paths for all customers"
}
