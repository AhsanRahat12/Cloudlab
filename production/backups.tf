## CNPG Backup Storage
# Shared storage account for all customer backups
# Each customer gets their own container via the customer-onboarding module

resource "azurerm_storage_account" "cnpg_backups" {
  name                     = "cloudlabbackupsprod"
  resource_group_name      = azurerm_resource_group.aks.name
  location                 = azurerm_resource_group.aks.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }
}
