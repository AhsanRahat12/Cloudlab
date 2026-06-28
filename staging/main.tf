resource "azurerm_resource_group" "aks" {
  name     = "rg-cloudlab-aks"
  location = "Canada Central"
}

## AKS Cluster with Best Practices
# Reference: https://learn.microsoft.com/en-us/azure/aks/best-practices

resource "azurerm_kubernetes_cluster" "main" {
  name                = "cloudlab-staging"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "staging"
  kubernetes_version  = "1.32.1"

  azure_active_directory_role_based_access_control {
    admin_group_object_ids = ["11d8fbe7-4ce4-4d24-a04b-c489e4cde806"]
  }

  # Automatic upgrades, patch level only for stability
  automatic_upgrade_channel = "patch"

  # Node OS auto-upgrade for security patches
  node_os_upgrade_channel = "NodeImage"

  # System node pool for critical Kubernetes components
  # Tainted with CriticalAddonsOnly so user workloads don't schedule here
  default_node_pool {
    name                         = "agentpool"
    node_count                   = 2
    vm_size                      = "Standard_D2s_v3"
    only_critical_addons_enabled = true # Adds CriticalAddonsOnly taint

    upgrade_settings {
      max_surge = "33%" # Recommended by microsoft
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "cilium"
    network_data_plane = "cilium"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }

  # Maintenance windows - schedule upgrades during low-traffic periods
  # Microsoft recommends at least 4 hours duration
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }
}

# User node pool - for application workloads
# No taint, so pods schedule here by default
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D2s_v3"
  node_count            = 2

  upgrade_settings {
    max_surge = "33%"
  }
}

## GitOps with Flux
# IMPORTANT: Register provider first: az provider register --namespace Microsoft.KubernetesConfiguration

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "cloudlab-flux"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "microsoft.flux"

  # Wait for user node pool to be ready before installing extensions
  # The system pool has CriticalAddonsOnly taint, so Flux needs user nodes
  depends_on = [azurerm_kubernetes_cluster_node_pool.user]
}

resource "azurerm_kubernetes_flux_configuration" "main" {
  name       = "cloudlab-staging"
  cluster_id = azurerm_kubernetes_cluster.main.id
  namespace  = "flux-system"

  git_repository {
    url             = "ssh://git@github.com/AhsanRahat12/Cloudlab.git"
    reference_type  = "branch"
    reference_value = "main"

    ssh_private_key_base64 = base64encode(file("~/.ssh/cloudlab-flux"))
  }

  kustomizations {
    name                       = "infra-controllers"
    path                       = "./infrastructure/controllers/staging"
    sync_interval_in_seconds   = 300
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "infra-configs"
    path                       = "./infrastructure/configs/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["infra-controllers"]
    garbage_collection_enabled = true
  }

  # CNPG plugin needs cert-manager (in infra-configs) to be ready
  # Apps depend on this plugin for database backups
  kustomizations {
    name                       = "cnpg-plugin"
    path                       = "./infrastructure/cnpg-plugin/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["infra-configs"]
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "monitoring-controllers"
    path                       = "./monitoring/controllers/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["apps"]
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "monitoring-configs"
    path                       = "./monitoring/configs/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["monitoring-controllers"]
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "apps"
    path                       = "./apps/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["cnpg-plugin"]
    garbage_collection_enabled = true
  }

  scope = "cluster"

  depends_on = [azurerm_kubernetes_cluster_extension.flux]
}

## Key Vault

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "cloudlab_vault" {
  name                = "kv-cloudlab-staging"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  rbac_authorization_enabled = true
  depends_on                 = [azurerm_kubernetes_cluster.main]
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.cloudlab_vault.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "aks_keyvault_secrets_provider" {
  scope                = azurerm_key_vault.cloudlab_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
}

## Grafana admin password (for monitoring)

resource "random_password" "grafana_admin" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "azurerm_key_vault_secret" "grafana_admin_password" {
  name         = "grafana-admin-password"
  value        = random_password.grafana_admin.result
  key_vault_id = azurerm_key_vault.cloudlab_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "grafana_admin_user" {
  name         = "grafana-admin-user"
  value        = "admin"
  key_vault_id = azurerm_key_vault.cloudlab_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

## Grafana Telegram credentials (dummy values for demo)

resource "azurerm_key_vault_secret" "grafana_telegram_bot_token" {
  name         = "grafana-telegram-bot-token"
  value        = "DEMO:dummy-bot-token-replace-me"
  key_vault_id = azurerm_key_vault.cloudlab_vault.id

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "grafana_telegram_chat_id" {
  name         = "grafana-telegram-chat-id"
  value        = "000000000"
  key_vault_id = azurerm_key_vault.cloudlab_vault.id

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_role_assignment.kv_admin]
}

## Storage account name in Key Vault (shared across all customers)

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "storage-account-name"
  value        = azurerm_storage_account.cnpg_backups.name
  key_vault_id = azurerm_key_vault.cloudlab_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}
