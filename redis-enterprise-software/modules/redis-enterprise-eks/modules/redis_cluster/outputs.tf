output "cluster_name" {
  description = "Name of the Redis Enterprise Cluster"
  value       = var.cluster_name
}

output "cluster_namespace" {
  description = "Kubernetes namespace of the Redis Enterprise cluster"
  value       = var.namespace
}

output "admin_credentials_secret_name" {
  description = "Name of the Kubernetes secret containing admin credentials"
  value       = kubernetes_secret.redis_enterprise_admin.metadata[0].name
}

output "node_count" {
  description = "Number of Redis Enterprise nodes"
  value       = var.node_count
}

output "api_loadbalancer_dns" {
  description = "DNS name of the API LoadBalancer (managed by ingress module)"
  value       = ""
}

output "rec_name" {
  description = "Name of the Redis Enterprise Cluster (REC)"
  value       = var.cluster_name
}

output "cluster_ready" {
  description = "Dependency output to ensure cluster is ready before creating dependent resources"
  value       = time_sleep.wait_for_cluster.id
}
