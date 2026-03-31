#==============================================================================
# OUTPUTS - DUAL REGION
#==============================================================================

output "region1_info" {
  description = "Region 1 cluster information"
  value = {
    region               = var.region1
    vpc_id               = module.region1.vpc_id
    eks_cluster_name     = module.region1.eks_cluster_name
    eks_cluster_endpoint = module.region1.eks_cluster_endpoint
    redis_namespace      = module.region1.redis_namespace
    redis_cluster_name   = module.region1.redis_cluster_name
  }
}

output "region2_info" {
  description = "Region 2 cluster information"
  value = {
    region               = var.region2
    vpc_id               = module.region2.vpc_id
    eks_cluster_name     = module.region2.eks_cluster_name
    eks_cluster_endpoint = module.region2.eks_cluster_endpoint
    redis_namespace      = module.region2.redis_namespace
    redis_cluster_name   = module.region2.redis_cluster_name
  }
}

output "vpc_peering_connection_id" {
  description = "VPC peering connection ID"
  value       = aws_vpc_peering_connection.region1_to_region2.id
}

output "configure_kubectl_region1" {
  description = "Command to configure kubectl for region 1"
  value       = "aws eks update-kubeconfig --region ${var.region1} --name ${module.region1.eks_cluster_name} --alias region1 --profile ${var.aws_profile}"
}

output "configure_kubectl_region2" {
  description = "Command to configure kubectl for region 2"
  value       = "aws eks update-kubeconfig --region ${var.region2} --name ${module.region2.eks_cluster_name} --alias region2 --profile ${var.aws_profile}"
}

output "verification_commands" {
  description = "Commands to verify the deployment"
  value       = <<-EOT
    # Configure kubectl for Region 1
    aws eks update-kubeconfig --region ${var.region1} --name ${module.region1.eks_cluster_name} --alias region1 --profile ${var.aws_profile}
    
    # Check Redis Enterprise Cluster in Region 1
    kubectl get rec -n ${module.region1.redis_namespace} --context region1
    kubectl get pods -n ${module.region1.redis_namespace} --context region1
    
    # Configure kubectl for Region 2
    aws eks update-kubeconfig --region ${var.region2} --name ${module.region2.eks_cluster_name} --alias region2 --profile ${var.aws_profile}
    
    # Check Redis Enterprise Cluster in Region 2
    kubectl get rec -n ${module.region2.redis_namespace} --context region2
    kubectl get pods -n ${module.region2.redis_namespace} --context region2
    
    # Manual checkpoint: upload the REC license in both admin UIs
    # before running the post-deployment CRDB workflow.
  EOT
}

output "next_steps" {
  description = "Next steps after deployment"
  value       = <<-EOT
    ✅ Infrastructure deployment complete.

    Both regions are deployed with independent Redis Enterprise clusters and
    cross-region prerequisites. VPC peering is configured between the regions.

    ✅ Configuration file generated: post-deployment/config.env

    Next steps:
    1. Validate configuration: ./validate-config.sh
    2. Verify both RECs are Running (see verification_commands output)
    3. Manually upload the Redis Enterprise license in both admin UIs
    4. Run post-license deployment: cd post-deployment && source config.env && ./deploy-all.sh
  EOT
}
