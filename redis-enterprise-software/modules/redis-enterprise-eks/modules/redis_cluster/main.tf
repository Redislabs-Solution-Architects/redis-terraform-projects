#==============================================================================
# REDIS ENTERPRISE CLUSTER CREDENTIALS SECRET
#==============================================================================

resource "kubernetes_secret" "redis_enterprise_admin" {
  metadata {
    name      = var.cluster_name # Must match cluster name exactly for bootstrapper
    namespace = var.namespace
  }

  # Kubernetes secrets with 'data' field are automatically base64 encoded by Terraform
  type = "Opaque"

  data = {
    username = var.admin_username
    password = var.admin_password
  }
}

# Bulletin board configmap required by bootstrapper
# NOTE: The bulletin board is managed by the Redis Enterprise operator after creation.
# Terraform only creates it initially with an empty value, then ignores changes.
resource "kubernetes_config_map" "bulletin_board" {
  metadata {
    name      = "${var.cluster_name}-bulletin-board"
    namespace = var.namespace
  }

  data = {
    BulletinBoard = ""
  }

  lifecycle {
    ignore_changes = [data]
  }
}

#==============================================================================
# REDIS ENTERPRISE CLUSTER (REC)
#==============================================================================

resource "kubectl_manifest" "redis_enterprise_cluster" {
  yaml_body = <<-YAML
    apiVersion: app.redislabs.com/v1
    kind: RedisEnterpriseCluster
    metadata:
      name: ${var.cluster_name}
      namespace: ${var.namespace}
      ${length(var.ui_service_annotations) > 0 ? "annotations:\n" + join("\n", [for k, v in var.ui_service_annotations : "        ${k}: \"${v}\""]) : ""}
    spec:
      nodes: ${var.node_count}

      # Resource allocation per node
      redisEnterpriseNodeResources:
        limits:
          cpu: "${var.node_cpu_limit}"
          memory: ${var.node_memory_limit}
        requests:
          cpu: "${var.node_cpu_request}"
          memory: ${var.node_memory_request}

      # Persistent storage configuration
      persistentSpec:
        enabled: true
        storageClassName: "${var.storage_class_name}"
        volumeSize: ${var.storage_size}

      # Admin credentials
      username: ${var.admin_username}
      # Secret name matches cluster name, so it will be auto-discovered

      # UI service configuration
      uiServiceType: ${var.ui_service_type}

      # Rack awareness for HA (distributes nodes across AZs)
      rackAwarenessNodeLabel: "topology.kubernetes.io/zone"

      # Security context - Enable automatic resource adjustment for Redis Enterprise 8.x
      # This grants SYS_RESOURCE capability required by pdns_server and other internal processes
      securityContext:
        resourceLimits:
          allowAutoAdjustment: true

      # Additional configuration
      redisEnterpriseImageSpec:
        imagePullPolicy: IfNotPresent
        ${var.redis_enterprise_version_tag != "" ? "versionTag: ${var.redis_enterprise_version_tag}" : ""}

      ${var.license_secret_name != "" ? "# License configuration\n      licenseSecretName: ${var.license_secret_name}" : ""}
%{if var.enable_redis_flex~}

      # Redis Flex (Auto Tiering) configuration for flash storage
      redisOnFlashSpec:
        enabled: true
        bigStoreDriver: ${var.redis_flex_storage_driver}
        storageClassName: "${var.redis_flex_storage_class}"
        flashDiskSize: ${var.redis_flex_flash_disk_size}
%{endif~}
%{if var.enable_ingress && var.api_fqdn_url != "" && var.db_fqdn_suffix != ""~}

      # Ingress/Route configuration for external access
      ingressOrRouteSpec:
        apiFqdnUrl: ${var.api_fqdn_url}
        dbFqdnSuffix: ${var.db_fqdn_suffix}
        method: ${var.ingress_method}
        ${var.ingress_method == "ingress" ? "ingressAnnotations:\n          ${join("\n          ", [for k, v in var.ingress_annotations : "${k}: \"${v}\""])}" : ""}
%{endif~}
  YAML

depends_on = [
  kubernetes_secret.redis_enterprise_admin
]
}

#==============================================================================
# WAIT FOR CLUSTER TO BE READY
#==============================================================================

resource "time_sleep" "wait_for_cluster" {
  depends_on = [kubectl_manifest.redis_enterprise_cluster]

  create_duration = "180s" # Wait 3 minutes for cluster to become ready
}

#==============================================================================
# CLEANUP ON DESTROY (prevents hanging)
#==============================================================================

resource "null_resource" "cleanup_on_destroy" {
  triggers = {
    rec_name         = var.cluster_name
    eks_cluster_name = var.eks_cluster_name
    aws_region       = var.aws_region
    namespace        = var.namespace
  }

  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      # Configure kubectl for the EKS cluster
      KUBEFILE=$(mktemp)
      aws eks update-kubeconfig --region ${self.triggers.aws_region} --name ${self.triggers.eks_cluster_name} --kubeconfig $KUBEFILE

      # Delete all REDBs first (databases)
      kubectl delete redb --all -n ${self.triggers.namespace} --ignore-not-found=true --timeout=120s --kubeconfig $KUBEFILE || true

      # Wait for databases to be fully deleted
      sleep 30

      # Delete the REC (cluster)
      kubectl delete rec ${self.triggers.rec_name} -n ${self.triggers.namespace} --ignore-not-found=true --timeout=120s --kubeconfig $KUBEFILE || true

      # Wait for cluster pods to terminate
      sleep 30

      # Force delete any remaining PVCs
      kubectl delete pvc --all -n ${self.triggers.namespace} --ignore-not-found=true --timeout=60s --kubeconfig $KUBEFILE || true

      # Cleanup temp file
      rm -f $KUBEFILE

      echo "Redis Enterprise cleanup completed"
    EOT
    on_failure = continue
  }

  depends_on = [kubectl_manifest.redis_enterprise_cluster]
}
