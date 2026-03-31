#==============================================================================
# CLUSTER INFORMATION
#==============================================================================

output "cluster_name" {
  description = "Name of the Redis Enterprise cluster"
  value       = local.name_prefix
}

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

#==============================================================================
# EKS CLUSTER OUTPUTS
#==============================================================================

output "eks_cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = module.eks.cluster_version
}

output "eks_cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

#==============================================================================
# EKS NODE GROUP OUTPUTS
#==============================================================================

output "eks_node_group_id" {
  description = "EKS node group ID"
  value       = module.eks_node_group.node_group_id
}

output "eks_node_group_status" {
  description = "Status of the EKS node group"
  value       = module.eks_node_group.node_group_status
}

output "eks_node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes"
  value       = module.eks_node_group.node_security_group_id
}

#==============================================================================
# NETWORK OUTPUTS
#==============================================================================

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

#==============================================================================
# REDIS ENTERPRISE OUTPUTS
#==============================================================================

output "redis_namespace" {
  description = "Kubernetes namespace where Redis Enterprise is deployed"
  value       = module.redis_operator.namespace
}

output "redis_operator_version" {
  description = "Version of the Redis Enterprise operator"
  value       = module.redis_operator.operator_version
}

output "redis_cluster_name" {
  description = "Name of the Redis Enterprise cluster (REC)"
  value       = module.redis_cluster.cluster_name
}

output "redis_cluster_nodes" {
  description = "Number of nodes in the Redis Enterprise cluster"
  value       = module.redis_cluster.node_count
}

output "redis_database_name" {
  description = "Name of the sample Redis database (if created)"
  value       = module.redis_database.database_name
}

output "redis_database_port" {
  description = "Port of the sample Redis database"
  value       = module.redis_database.database_port
}

#==============================================================================
# STORAGE OUTPUTS
#==============================================================================

output "storage_class_name" {
  description = "Name of the storage class used for Redis Enterprise"
  value       = module.ebs_csi_driver.storage_class_name
}

output "ebs_csi_driver_version" {
  description = "Version of the EBS CSI driver addon"
  value       = module.ebs_csi_driver.ebs_csi_addon_version
}

#==============================================================================
# KUBECTL CONFIG
#==============================================================================

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.name_prefix}"
}

#==============================================================================
# ACCESS INSTRUCTIONS
#==============================================================================

output "access_instructions" {
  description = "Instructions for accessing the Redis Enterprise cluster"
  value       = <<-EOT

    ╔════════════════════════════════════════════════════════════════════════════╗
    ║            REDIS ENTERPRISE ON EKS - ACCESS INSTRUCTIONS                   ║
    ╚════════════════════════════════════════════════════════════════════════════╝

    ACCESS MODE: ${var.redis_ui_service_type == "ClusterIP" ? "Internal (ClusterIP)" : "External (LoadBalancer)"}
    DATABASE SERVICE: ${var.redis_database_service_type == "ClusterIP" ? "Internal (ClusterIP)" : "External (LoadBalancer)"}

    1. CONFIGURE KUBECTL
       aws eks update-kubeconfig --region ${var.aws_region} --name ${local.name_prefix}

    2. VERIFY CLUSTER STATUS
       kubectl get rec -n ${module.redis_operator.namespace}
       kubectl get pods -n ${module.redis_operator.namespace}
       kubectl get svc -n ${module.redis_operator.namespace}

    3. ACCESS REDIS ENTERPRISE UI
       ${var.redis_ui_service_type == "ClusterIP" ? "# Port-forward to access UI from your local machine:\n       kubectl port-forward -n ${module.redis_operator.namespace} svc/${var.cluster_name}-ui 8443:8443\n       \n       # Then access: https://localhost:8443" : "# Access via LoadBalancer (get external IP):\n       kubectl get svc ${var.cluster_name}-ui -n ${module.redis_operator.namespace}"}

       Username: ${var.redis_cluster_username}
       Password: [your configured password]

    ${var.create_sample_database ? "4. ACCESS SAMPLE DATABASE\n       ${var.sample_db_service_type == "ClusterIP" ? "# Port-forward for local access:\n       kubectl port-forward -n ${module.redis_operator.namespace} svc/${var.sample_db_name} ${var.sample_db_port}:${var.sample_db_port}\n       redis-cli -h localhost -p ${var.sample_db_port}" : "# Access via LoadBalancer (get external IP):\n       kubectl get svc ${var.sample_db_name} -n ${module.redis_operator.namespace}"}\n" : ""}
    5. DEPLOY TEST APPLICATION (to access Redis from inside cluster)
       kubectl run redis-test --image=redis:latest -n ${module.redis_operator.namespace} --rm -it -- bash
       # Inside the pod:
       redis-cli -h ${var.sample_db_name} -p ${var.sample_db_port}

    6. VIEW CLUSTER LOGS
       kubectl logs -n ${module.redis_operator.namespace} -l app=redis-enterprise --tail=100

    7. GET ADMIN PASSWORD (if forgotten)
       kubectl get secret ${module.redis_cluster.admin_credentials_secret_name} -n ${module.redis_operator.namespace} -o jsonpath='{.data.password}' | base64 -d

    ${var.redis_enable_ingress ? "\n    INGRESS ENABLED:\n    - API FQDN: ${var.redis_api_fqdn_url}\n    - DB FQDN Suffix: ${var.redis_db_fqdn_suffix}\n    - Method: ${var.redis_ingress_method}\n" : "\n    For external access via ingress, set redis_enable_ingress = true in terraform.tfvars\n"}
    ════════════════════════════════════════════════════════════════════════════
  EOT
}

#==============================================================================
# NEXT STEPS
#==============================================================================

output "next_steps" {
  description = "Recommended next steps after deployment"
  value       = <<-EOT

    ╔════════════════════════════════════════════════════════════════════════════╗
    ║                            NEXT STEPS                                      ║
    ╚════════════════════════════════════════════════════════════════════════════╝

    ✓ EKS cluster deployed successfully
    ✓ Redis Enterprise operator installed (bundle: ${var.redis_operator_version})
    ✓ Redis Enterprise cluster created (${var.redis_cluster_nodes} nodes, HA enabled)
    ${var.create_sample_database ? "✓ Sample database '${var.sample_db_name}' created (${var.sample_db_shard_count} shard${var.sample_db_shard_count > 1 ? "s" : ""}, HA ${var.sample_db_replication ? "enabled" : "disabled"})\n" : ""}

    RECOMMENDED ACTIONS:

    1. Configure kubectl and verify cluster health
    2. ${var.redis_ui_service_type == "ClusterIP" ? "Use port-forward to access UI locally" : "Access UI via LoadBalancer external IP"}
    3. Deploy applications in the cluster to access Redis
    4. Create additional databases as needed
    5. ${var.redis_enable_ingress ? "Configure DNS for ingress endpoints" : "Enable ingress for external access (set redis_enable_ingress=true)"}
    6. Set up monitoring and alerting
    7. Configure backup strategies
    8. Review security settings (TLS, network policies, certificates)

    USEFUL COMMANDS:

    # Watch cluster status
    kubectl get rec -n ${module.redis_operator.namespace} -w

    # View operator logs
    kubectl logs -n ${module.redis_operator.namespace} -l name=redis-enterprise-operator --tail=50

    # Create additional database
    kubectl apply -f your-database.yaml

    # Scale node group (if needed)
    aws eks update-nodegroup-config --cluster-name ${local.name_prefix} \
      --nodegroup-name ${local.name_prefix}-node-group --scaling-config desiredSize=5

    ════════════════════════════════════════════════════════════════════════════
  EOT
}
