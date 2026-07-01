## Customer Onboarding
# Add a customer name to this list to provision their entire infrastructure
# Terraform will create: storage container, Key Vault secrets, and GitOps manifests

locals {
  customers = toset([
    "luffy",
    "zoro",
    "nami",
  ])

  environment      = "production"
  domain           = "cloudlab.rahatahsan.com"
  gitops_repo_path = "/home/rahat/Projects/Cloudlab"

  customers_sorted = sort(tolist(local.customers))
}

module "customer" {
  source   = "../modules/customer-onboarding"
  for_each = local.customers

  customer_name = each.key
  environment   = local.environment
  # Sizing (use defaults, override per-customer if needed)
  db_instances     = 1

  key_vault_id                              = azurerm_key_vault.cloudlab_vault.id
  storage_account_id                        = azurerm_storage_account.cnpg_backups.id
  storage_account_name                      = azurerm_storage_account.cnpg_backups.name
  storage_account_primary_connection_string = azurerm_storage_account.cnpg_backups.primary_connection_string

  keyvault_name                   = azurerm_key_vault.cloudlab_vault.name
  keyvault_tenant_id              = data.azurerm_client_config.current.tenant_id
  aks_keyvault_identity_client_id = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id

  gitops_repo_path = local.gitops_repo_path
  domain           = local.domain

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "local_file" "production_kustomization" {
  filename = "${local.gitops_repo_path}/apps/production/kustomization.yaml"
  content  = <<-YAML
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
    %{for customer in local.customers_sorted~}
      - ${customer}
    %{endfor~}
  YAML
  depends_on = [module.customer]
}
