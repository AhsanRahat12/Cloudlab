# GitOps Manifest Generation
# Creates all Kubernetes manifests for a customer in the GitOps repository
# Each environment gets its own complete set of manifests (no shared base)

locals {
  customer_path = "${var.gitops_repo_path}/apps/${var.environment}/${var.customer_name}"
}

# Ensure the customer directory exists
resource "local_file" "directory_marker" {
  filename = "${local.customer_path}/.gitkeep"
  content  = ""
}

# 1. Namespace with Pod Security Standards
resource "local_file" "namespace" {
  filename = "${local.customer_path}/namespace.yaml"
  content  = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${var.customer_name}
      labels:
        pod-security.kubernetes.io/enforce: restricted
  YAML

  depends_on = [local_file.directory_marker]
}

# 2. SecretProviderClass for Azure Key Vault CSI
resource "local_file" "secrets" {
  filename = "${local.customer_path}/secrets.yaml"
  content  = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: ${var.customer_name}-secrets
    spec:
      provider: azure
      parameters:
        usePodIdentity: "false"
        useVMManagedIdentity: "true"
        userAssignedIdentityID: "${var.aks_keyvault_identity_client_id}"
        keyvaultName: "${var.keyvault_name}"
        tenantId: "${var.keyvault_tenant_id}"
        objects: |
          array:
            - |
              objectName: ${var.customer_name}-db-user
              objectType: secret
            - |
              objectName: ${var.customer_name}-db-password
              objectType: secret
            - |
              objectName: storage-account-name
              objectType: secret
            - |
              objectName: ${var.customer_name}-blob-sas
              objectType: secret
            - |
              objectName: ${var.customer_name}-telegram-bot-token
              objectType: secret
            - |
              objectName: ${var.customer_name}-telegram-chat-id
              objectType: secret
      secretObjects:
        - secretName: ${var.customer_name}-db-credentials
          type: kubernetes.io/basic-auth
          data:
            - objectName: ${var.customer_name}-db-user
              key: username
            - objectName: ${var.customer_name}-db-password
              key: password
        - secretName: ${var.customer_name}-n8n-env
          type: Opaque
          data:
            - objectName: ${var.customer_name}-db-user
              key: DB_POSTGRESDB_USER
            - objectName: ${var.customer_name}-db-password
              key: DB_POSTGRESDB_PASSWORD
        - secretName: ${var.customer_name}-backup-creds
          type: Opaque
          data:
            - objectName: storage-account-name
              key: storage-account-name
            - objectName: ${var.customer_name}-blob-sas
              key: ${var.customer_name}-blob-sas
        - secretName: ${var.customer_name}-telegram-creds
          type: Opaque
          data:
            - objectName: ${var.customer_name}-telegram-bot-token
              key: TELEGRAM_BOT_TOKEN
            - objectName: ${var.customer_name}-telegram-chat-id
              key: TELEGRAM_CHAT_ID
  YAML

  depends_on = [local_file.directory_marker]
}

# 3. ConfigMap for n8n configuration
resource "local_file" "configmap" {
  filename = "${local.customer_path}/configmap.yaml"
  content  = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${var.customer_name}-n8n-config
    data:
      N8N_PORT: "3008"
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_SECURE_COOKIE: "true"
      DB_TYPE: "postgresdb"
      DB_POSTGRESDB_HOST: "${var.customer_name}-db-rw.${var.customer_name}.svc.cluster.local"
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: "app"
  YAML

  depends_on = [local_file.directory_marker]
}

# 4. CNPG Database Cluster
resource "local_file" "database" {
  filename = "${local.customer_path}/database.yaml"
  content  = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: ${var.customer_name}-db
    spec:
      instances: ${var.db_instances}

      bootstrap:
        initdb:
          database: app
          owner: app
          secret:
            name: ${var.customer_name}-db-credentials

      # Point-in-Time Recovery (PITR) - uncomment to restore from backup
      # bootstrap:
      #   recovery:
      #     database: app
      #     owner: app
      #     source: source
      #     secret:
      #       name: ${var.customer_name}-db-credentials
      #
      # externalClusters:
      #   - name: source
      #     plugin:
      #       name: barman-cloud.cloudnative-pg.io
      #       parameters:
      #         barmanObjectName: ${var.customer_name}-objectstore
      #         serverName: ${var.customer_name}-db

      storage:
        size: ${var.db_storage_size}

      plugins:
        - name: barman-cloud.cloudnative-pg.io
          isWALArchiver: true
          parameters:
            barmanObjectName: ${var.customer_name}-objectstore
  YAML

  depends_on = [local_file.directory_marker]
}

# 5. Barman ObjectStore for backups
resource "local_file" "objectstore" {
  filename = "${local.customer_path}/objectstore.yaml"
  content  = <<-YAML
    apiVersion: barmancloud.cnpg.io/v1
    kind: ObjectStore
    metadata:
      name: ${var.customer_name}-objectstore
    spec:
      configuration:
        destinationPath: "https://${var.storage_account_name}.blob.core.windows.net/${var.customer_name}"
        azureCredentials:
          storageAccount:
            name: ${var.customer_name}-backup-creds
            key: storage-account-name
          storageSasToken:
            name: ${var.customer_name}-backup-creds
            key: ${var.customer_name}-blob-sas
      retentionPolicy: "14d"
  YAML

  depends_on = [local_file.directory_marker]
}

# 6. Scheduled Backup
resource "local_file" "scheduled_backup" {
  filename = "${local.customer_path}/scheduled-backup.yaml"
  content  = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: ScheduledBackup
    metadata:
      name: ${var.customer_name}-db-backup
    spec:
      schedule: "0 0 3 * * *"
      backupOwnerReference: cluster
      cluster:
        name: ${var.customer_name}-db
  YAML

  depends_on = [local_file.directory_marker]
}

# 7. n8n Deployment (PSS restricted compliant)
resource "local_file" "deployment" {
  filename = "${local.customer_path}/deployment.yaml"
  content  = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${var.customer_name}-n8n
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: ${var.customer_name}-n8n
      strategy:
        type: Recreate

      template:
        metadata:
          labels:
            app: ${var.customer_name}-n8n

        spec:
          # Pod-level security context (PSS restricted compliance)
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault

          containers:
            - name: n8n
              image: docker.n8n.io/n8nio/n8n:${var.n8n_version}

              # Container-level security context (PSS restricted compliance)
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL

              # Resource management
              resources:
                requests:
                  memory: "${var.n8n_memory_request}"
                  cpu: "${var.n8n_cpu_request}"
                limits:
                  memory: "${var.n8n_memory_limit}"
                  cpu: "${var.n8n_cpu_limit}"

              # Health checks
              livenessProbe:
                httpGet:
                  path: /healthz
                  port: 3008
                initialDelaySeconds: 30
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 3

              readinessProbe:
                httpGet:
                  path: /healthz
                  port: 3008
                initialDelaySeconds: 5
                periodSeconds: 5
                timeoutSeconds: 3
                failureThreshold: 3

              envFrom:
                - configMapRef:
                    name: ${var.customer_name}-n8n-config
                - secretRef:
                    name: ${var.customer_name}-n8n-env

              ports:
                - containerPort: 3008
                  protocol: TCP

              volumeMounts:
                - mountPath: /home/node/.n8n
                  name: n8n-data
                - mountPath: /mnt/secrets-store
                  name: secrets-store
                  readOnly: true
                # Required for readOnlyRootFilesystem
                - mountPath: /tmp
                  name: tmp
                - mountPath: /home/node/.cache
                  name: cache

          restartPolicy: Always

          volumes:
            - name: n8n-data
              persistentVolumeClaim:
                claimName: ${var.customer_name}-n8n-data
            - name: secrets-store
              csi:
                driver: secrets-store.csi.k8s.io
                readOnly: true
                volumeAttributes:
                  secretProviderClass: ${var.customer_name}-secrets
            # EmptyDir volumes for writable paths
            - name: tmp
              emptyDir: {}
            - name: cache
              emptyDir: {}
  YAML

  depends_on = [local_file.directory_marker]
}

# 8. Service
resource "local_file" "service" {
  filename = "${local.customer_path}/service.yaml"
  content  = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: ${var.customer_name}-n8n
    spec:
      selector:
        app: ${var.customer_name}-n8n
      ports:
        - port: 3008
  YAML

  depends_on = [local_file.directory_marker]
}

# 9. Ingress with TLS
resource "local_file" "ingress" {
  filename = "${local.customer_path}/ingress.yaml"
  content  = <<-YAML
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: ${var.customer_name}-ingress
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod
    spec:
      ingressClassName: traefik
      tls:
        - hosts:
            - ${var.customer_name}.${var.domain}
          secretName: ${var.customer_name}-tls
      rules:
        - host: ${var.customer_name}.${var.domain}
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: ${var.customer_name}-n8n
                    port:
                      number: 3008
  YAML

  depends_on = [local_file.directory_marker]
}

# 10. Cilium Network Policy
resource "local_file" "network_policy" {
  filename = "${local.customer_path}/network-policy.yaml"
  content  = <<-YAML
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: ${var.customer_name}-n8n
    spec:
      endpointSelector:
        matchLabels:
          app: ${var.customer_name}-n8n

      ingress:
        # Allow from Traefik ingress controller
        - fromEndpoints:
            - matchLabels:
                k8s:io.kubernetes.pod.namespace: traefik
          toPorts:
            - ports:
                - port: "3008"
                  protocol: TCP

      egress:
        # Allow to CNPG database
        - toEndpoints:
            - matchLabels:
                cnpg.io/cluster: ${var.customer_name}-db
          toPorts:
            - ports:
                - port: "5432"
                  protocol: TCP
        # Allow DNS resolution
        - toEndpoints:
            - matchLabels:
                k8s:io.kubernetes.pod.namespace: kube-system
                k8s-app: kube-dns
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
        # Allow external HTTPS (for webhooks, integrations)
        - toEntities:
            - world
          toPorts:
            - ports:
                - port: "443"
                  protocol: TCP
  YAML

  depends_on = [local_file.directory_marker]
}

# 11. PersistentVolumeClaim for n8n data
resource "local_file" "storage" {
  filename = "${local.customer_path}/storage.yaml"
  content  = <<-YAML
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ${var.customer_name}-n8n-data
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: ${var.n8n_storage_size}
  YAML

  depends_on = [local_file.directory_marker]
}

# 12. Kustomization
resource "local_file" "kustomization" {
  filename = "${local.customer_path}/kustomization.yaml"
  content  = <<-YAML
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    namespace: ${var.customer_name}
    resources:
      - namespace.yaml
      - secrets.yaml
      - configmap.yaml
      - storage.yaml
      - database.yaml
      - objectstore.yaml
      - scheduled-backup.yaml
      - deployment.yaml
      - service.yaml
      - ingress.yaml
      - network-policy.yaml
  YAML

  depends_on = [local_file.directory_marker]
}


