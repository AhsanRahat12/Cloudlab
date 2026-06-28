# Customer Onboarding Module
# Creates Azure resources and generates GitOps manifests for a new customer

# Storage container for CNPG backups
resource "azurerm_storage_container" "customer" {
  name                  = var.customer_name
  storage_account_id    = var.storage_account_id
  container_access_type = "private"
}

# SAS token for backup access (2-year expiry)
data "azurerm_storage_account_blob_container_sas" "customer" {
  connection_string = var.storage_account_primary_connection_string
  container_name    = azurerm_storage_container.customer.name
  https_only        = true

  start  = timestamp()
  expiry = timeadd(timestamp(), "17520h") # 2 years

  permissions {
    read   = true
    write  = true
    delete = true
    list   = true
    add    = true
    create = true
  }
}

