# ☁️ Cloudlab

Multi-tenant SaaS platform on Azure AKS — Terraform provisions the cloud infrastructure and generates the GitOps manifests, Flux syncs them to the cluster. Onboarding a new customer is a one-line change to a Terraform list.

---

## Philosophy

Two layers, two tools, one boundary. Terraform owns everything with state: the AKS cluster, node pools, Key Vault, storage accounts, secrets, per-customer Azure resources. Flux owns everything that's just declarative YAML: workloads, ingress, network policy, monitoring. Terraform writes the YAML into this repo as a side effect of provisioning a customer — it never talks to the Kubernetes API directly.

Customer onboarding is a single Terraform module (`modules/customer-onboarding`) invoked once per name in a `customers` set. Adding a customer means adding a string and running `terraform apply` — Terraform creates the Azure Blob container, Key Vault secrets, and 13 Kubernetes manifests, then commits the last piece itself: the kustomization that lists every customer directory.

Environments are fully isolated, not overlays of a shared base. `staging` and `production` are separate Terraform root modules, separate AKS clusters, separate Key Vaults, separate storage accounts — deliberately, so a mistake in staging can't touch production state.

Every customer is a Postgres database (CloudNative-PG) plus an n8n instance, network-isolated with Cilium, backed up continuously to Azure Blob via the Barman Cloud plugin, and deployed under Pod Security Standards `restricted` from day one.

---

## 🧰 Stack

| Tool | Purpose |
|------|---------|
| Terraform | Provisions AKS, Key Vault, storage, and per-customer Azure resources; generates GitOps manifests |
| AKS | Managed Kubernetes — system pool tainted `CriticalAddonsOnly`, user pool for workloads |
| Flux | GitOps controller — deployed as an AKS extension, syncs cluster state from this repo |
| Kustomize | Environment-specific configuration and overlays |
| Cilium | CNI + network policy — per-customer network isolation |
| Traefik | Ingress controller |
| cert-manager | Automated TLS via Let's Encrypt |
| Azure Key Vault + CSI driver | Secret storage — synced into pods via `SecretProviderClass`, no secrets in Git |
| CloudNative-PG | PostgreSQL operator — one dedicated cluster per customer |
| Barman Cloud plugin | Continuous WAL archiving and scheduled backups to Azure Blob Storage |
| n8n | Workflow automation app — the actual product each customer runs |
| kube-prometheus-stack | Prometheus + Grafana + Alertmanager |
| Grafana alerting | Provisioned contact points/policies — routes to Telegram |

---

## 📁 Repository Structure

```
Cloudlab/
├── staging/                        ← Terraform root module — staging AKS cluster
│   ├── main.tf                     ← AKS cluster, Flux extension, Key Vault
│   ├── customers.tf                ← customer list — add a name here to onboard
│   ├── backups.tf                  ← shared storage account for CNPG backups
│   └── outputs.tf
├── production/                     ← Terraform root module — production AKS cluster (mirrors staging)
├── modules/
│   └── customer-onboarding/        ← the onboarding module
│       ├── main.tf                 ← Azure Blob container + SAS token per customer
│       ├── secrets.tf              ← Key Vault secrets (db creds, blob SAS, Telegram)
│       └── gitops.tf               ← generates all 13 K8s manifests via local_file
├── apps/
│   ├── staging/<customer>/         ← generated per-customer manifests (namespace → ingress)
│   └── production/<customer>/
├── infrastructure/
│   ├── controllers/{base,staging,production}/   ← Traefik, cert-manager, CNPG operator (Helm via Flux)
│   ├── configs/{base,staging,production}/       ← cert-manager ClusterIssuers
│   └── cnpg-plugin/{base,staging,production}/   ← Barman Cloud plugin for CNPG
└── monitoring/
    ├── controllers/{base,staging,production}/   ← kube-prometheus-stack Helm release
    └── configs/{base,staging,production}/       ← Grafana alert rules, contact points, notification policies
```

Flux watches five dependency-chained Kustomizations per environment: `infra-controllers` → `infra-configs` → `cnpg-plugin` → `apps` → `monitoring-controllers` → `monitoring-configs`. Apps wait on the CNPG plugin because every customer's database backup config depends on it being ready.

---

## 👥 Customer Onboarding

Each entry in `customers.tf`'s `customers` set produces, via `modules/customer-onboarding`:

**Azure resources:** a private Blob container for backups, a 2-year SAS token, and 6 Key Vault secrets (db user/password, blob SAS, Telegram bot token/chat ID).

**Kubernetes manifests** (`apps/<env>/<customer>/`): namespace (PSS `restricted`), `SecretProviderClass` pulling all 6 secrets from Key Vault, CNPG `Cluster` + `ObjectStore` + `ScheduledBackup` (daily, 14-day retention), n8n `Deployment` (non-root, read-only rootfs, all capabilities dropped) + `Service` + PVC, Traefik `Ingress` with automatic TLS at `<customer>.cloudlab.rahatahsan.com`, a `CiliumNetworkPolicy` restricting ingress to Traefik and egress to the customer's own database plus DNS and HTTPS, and a `PodMonitor` for CNPG metrics.

Terraform writes each customer's directory itself, then regenerates the environment's `kustomization.yaml` listing every customer — so the file that wires everything into Flux is never hand-edited.

Current tenants (both environments): `luffy`, `zoro`, `nami`.

---

## 📊 Infrastructure & Data

**Compute:** AKS with a tainted system pool (`CriticalAddonsOnly`) isolating control-plane-adjacent workloads from a separate user pool where all customer and app workloads land. Automatic patch-level upgrades and node OS image upgrades, both confined to a weekly Sunday 02:00 UTC maintenance window.

**Secrets:** Azure Key Vault is the single source of truth. The AKS Key Vault Secrets Provider (managed identity) mounts secrets into pods via CSI `SecretProviderClass` — nothing sensitive is committed to Git, even encrypted.

**Backups:** Each customer's Postgres cluster streams WAL continuously to its own private Blob container via the Barman Cloud plugin, with daily scheduled backups and 14-day retention — isolated per tenant, so one customer's backup volume or access can't affect another's.

**Monitoring:** kube-prometheus-stack per environment. Grafana alert rules cover node health, pod health, CNPG operator health, per-customer database health, and n8n health, routed through a provisioned Telegram contact point with a 4-hour repeat interval.

---

## 🔥 Notable Decisions

- **Terraform generates GitOps YAML instead of a Helm chart or templating engine** — every customer's manifests are plain, readable YAML committed to Git, not rendered at apply time from a template a human has to mentally expand.
- **No shared `base/` for customer apps** — each environment's customer manifests are fully self-contained. Staging and production customers can diverge (sizing, instance count) without an overlay abstraction to fight.
- **`db_instances = 1` in both environments** — reduced from the module's HA default of 3 due to a demo-environment vCPU quota constraint, not a design choice; the module still defaults to 3 for future capacity.
- **Cilium network policy egress is scoped per customer's own CNPG cluster label** — one tenant's n8n pod cannot reach another tenant's database even though they share the same cluster and CNI.
- **SAS tokens and Telegram credentials use `lifecycle { ignore_changes }`** — so `terraform apply` doesn't churn secrets that are meant to be rotated manually or regenerate on every plan.

---

## 🌐 Connect

[LinkedIn](https://www.linkedin.com/in/rahatahsan/) &nbsp;•&nbsp; [Twitter/X](https://x.com/RahatAhsan20) &nbsp;•&nbsp; [GitHub (Main Profile)](https://github.com/AhsanRahat12) &nbsp;•&nbsp; [Medium](https://medium.com/@s.rahatahsan)
