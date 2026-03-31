#==============================================================================
# DUAL-REGION VARIABLES
#==============================================================================

variable "region1" {
  description = "First AWS region"
  type        = string
  default     = "us-east-1"
}

variable "region2" {
  description = "Second AWS region"
  type        = string
  default     = "us-west-2"
}

variable "region1_vpc_cidr" {
  description = "VPC CIDR for region 1"
  type        = string
  default     = "10.1.0.0/16"
}

variable "region2_vpc_cidr" {
  description = "VPC CIDR for region 2"
  type        = string
  default     = "10.2.0.0/16"
}

variable "region1_availability_zones" {
  description = "Availability zones for region 1 (leave empty for auto-select)"
  type        = list(string)
  default     = []
}

variable "region2_availability_zones" {
  description = "Availability zones for region 2 (leave empty for auto-select)"
  type        = list(string)
  default     = []
}

#==============================================================================
# BASIC CONFIGURATION (shared across both regions)
#==============================================================================

variable "project_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "default"
}

variable "cluster_name" {
  description = "Name of the Redis cluster"
  type        = string
  default     = "redis-enterprise"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "redis-enterprise-dual-region"
}

variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner/team name"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

#==============================================================================
# NETWORK CONFIGURATION (shared across both regions)
#==============================================================================

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway for all private subnets"
  type        = bool
  default     = false
}

#==============================================================================
# EKS CONFIGURATION (shared defaults, can be overridden per region)
#==============================================================================

variable "eks_cluster_version" {
  description = "Kubernetes version (shared across both regions)"
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS nodes (default for both regions)"
  type        = list(string)
  default     = ["r7i.8xlarge"]
}

variable "node_desired_size" {
  description = "Desired number of nodes (default for both regions)"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of nodes (default for both regions)"
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum number of nodes (default for both regions)"
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Disk size for nodes in GB (default for both regions)"
  type        = number
  default     = 100
}

#==============================================================================
# REGION 1 EKS OVERRIDES (optional - uses shared defaults if not specified)
#==============================================================================

variable "region1_node_instance_types" {
  description = "EC2 instance types for Region 1 EKS nodes (overrides node_instance_types)"
  type        = list(string)
  default     = null
}

variable "region1_node_desired_size" {
  description = "Desired number of nodes for Region 1 (overrides node_desired_size)"
  type        = number
  default     = null
}

variable "region1_node_min_size" {
  description = "Minimum number of nodes for Region 1 (overrides node_min_size)"
  type        = number
  default     = null
}

variable "region1_node_max_size" {
  description = "Maximum number of nodes for Region 1 (overrides node_max_size)"
  type        = number
  default     = null
}

variable "region1_node_disk_size" {
  description = "Disk size for Region 1 nodes in GB (overrides node_disk_size)"
  type        = number
  default     = null
}

#==============================================================================
# REGION 2 EKS OVERRIDES (optional - uses shared defaults if not specified)
#==============================================================================

variable "region2_node_instance_types" {
  description = "EC2 instance types for Region 2 EKS nodes (overrides node_instance_types)"
  type        = list(string)
  default     = null
}

variable "region2_node_desired_size" {
  description = "Desired number of nodes for Region 2 (overrides node_desired_size)"
  type        = number
  default     = null
}

variable "region2_node_min_size" {
  description = "Minimum number of nodes for Region 2 (overrides node_min_size)"
  type        = number
  default     = null
}

variable "region2_node_max_size" {
  description = "Maximum number of nodes for Region 2 (overrides node_max_size)"
  type        = number
  default     = null
}

variable "region2_node_disk_size" {
  description = "Disk size for Region 2 nodes in GB (overrides node_disk_size)"
  type        = number
  default     = null
}

#==============================================================================
# REDIS ENTERPRISE CONFIGURATION (shared across both regions)
#==============================================================================

variable "redis_operator_version" {
  description = "Redis Enterprise operator version (e.g., 'v8.0.10-23')"
  type        = string
  default     = "v8.0.10-23"
}

variable "redis_enterprise_version_tag" {
  description = "Redis Enterprise image version tag (e.g., '8.0.10-81')"
  type        = string
  default     = "8.0.10-81"
}

variable "redis_nodes" {
  description = "Number of Redis Enterprise nodes"
  type        = number
  default     = 3
}

variable "redis_cluster_username" {
  description = "Redis Enterprise cluster admin username"
  type        = string
  default     = "admin@redis.com"
}

variable "redis_cluster_password" {
  description = "Redis Enterprise cluster admin password"
  type        = string
  sensitive   = true
}

variable "redis_node_memory" {
  description = "Memory per Redis node (e.g., 4Gi)"
  type        = string
  default     = "4Gi"
}

variable "redis_node_cpu" {
  description = "CPU per Redis node (e.g., 2000m)"
  type        = string
  default     = "2000m"
}

variable "redis_persistent_storage" {
  description = "Enable persistent storage for Redis"
  type        = bool
  default     = true
}

variable "redis_storage_size" {
  description = "Storage size per Redis node (e.g., 50Gi)"
  type        = string
  default     = "50Gi"
}

variable "redis_ui_service_type" {
  description = "Service type for Redis UI (ClusterIP or LoadBalancer)"
  type        = string
  default     = "ClusterIP"
}

#==============================================================================
# SAMPLE DATABASE (optional, shared across both regions)
#==============================================================================

variable "create_sample_database" {
  description = "Create a sample Redis database for testing"
  type        = bool
  default     = false
}

variable "sample_db_name" {
  description = "Name of the sample database"
  type        = string
  default     = "sample-db"
}

variable "sample_db_port" {
  description = "Port for the sample database"
  type        = number
  default     = 12000
}

variable "sample_db_memory" {
  description = "Memory for the sample database (e.g., 1GB)"
  type        = string
  default     = "1GB"
}

variable "sample_db_replication" {
  description = "Enable replication for sample database"
  type        = bool
  default     = true
}

variable "sample_db_shard_count" {
  description = "Number of shards for sample database"
  type        = number
  default     = 1
}

variable "sample_db_service_type" {
  description = "Service type for sample database (ClusterIP or LoadBalancer)"
  type        = string
  default     = "ClusterIP"
}

#==============================================================================
# EXTERNAL ACCESS CONFIGURATION
#==============================================================================
# Controls external access to Redis Enterprise clusters and databases
#
# Two types of external access:
# 1. Client Access (external_access_type): For clients connecting to databases
#    - Options: "none", "nginx-ingress", "aws-lb"
#    - Creates Ingress resources for individual databases and UI
#
# 2. Cluster-to-Cluster Access (redis_enable_ingress): For Active-Active
#    - REQUIRED for Active-Active databases (REAADB)
#    - Configures ingressOrRouteSpec on REC resource
#    - Enables clusters to communicate for replication
#==============================================================================

#------------------------------------------------------------------------------
# Client Access Configuration (Optional - for database/UI access)
#------------------------------------------------------------------------------

variable "external_access_type" {
  description = "External access type for databases and UI (none, nginx-ingress, aws-lb)"
  type        = string
  default     = "none"
}

variable "enable_tls" {
  description = "Enable TLS for external access"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Cluster-to-Cluster Access (REQUIRED for Active-Active)
#------------------------------------------------------------------------------
# This configures the ingressOrRouteSpec field on the REC resource
# See: https://redis.io/docs/latest/operate/kubernetes/networking/ingressorroutespec/
#------------------------------------------------------------------------------

variable "redis_enable_ingress" {
  description = "Enable ingressOrRouteSpec on REC (REQUIRED for Active-Active)"
  type        = bool
  default     = false
}

variable "redis_ingress_method" {
  description = "Ingress method: 'ingress' for NGINX/HAProxy or 'openShiftRoute'"
  type        = string
  default     = "ingress"

  validation {
    condition     = contains(["ingress", "openShiftRoute"], var.redis_ingress_method)
    error_message = "redis_ingress_method must be 'ingress' or 'openShiftRoute'"
  }
}

#------------------------------------------------------------------------------
# Region 1 Ingress Configuration
#------------------------------------------------------------------------------

variable "region1_redis_api_fqdn_url" {
  description = "FQDN for Redis Enterprise API in Region 1 (format: api-<rec-name>-<namespace>.<domain>)"
  type        = string
  default     = ""

  # Example: "api-rec-region1-redis-enterprise.example.com"
}

variable "region1_redis_db_fqdn_suffix" {
  description = "FQDN suffix for Redis databases in Region 1 (format: -db-<rec-name>-<namespace>.<domain>)"
  type        = string
  default     = ""

  # Example: "-db-rec-region1-redis-enterprise.example.com"
}

#------------------------------------------------------------------------------
# Region 2 Ingress Configuration
#------------------------------------------------------------------------------

variable "region2_redis_api_fqdn_url" {
  description = "FQDN for Redis Enterprise API in Region 2 (format: api-<rec-name>-<namespace>.<domain>)"
  type        = string
  default     = ""

  # Example: "api-rec-region2-redis-enterprise.example.com"
}

variable "region2_redis_db_fqdn_suffix" {
  description = "FQDN suffix for Redis databases in Region 2 (format: -db-<rec-name>-<namespace>.<domain>)"
  type        = string
  default     = ""

  # Example: "-db-rec-region2-redis-enterprise.example.com"
}

#------------------------------------------------------------------------------
# Ingress Domain (Optional - for client access via external_access module)
#------------------------------------------------------------------------------

variable "ingress_domain" {
  description = "Base domain for ingress (used by external_access module for database/UI access)"
  type        = string
  default     = ""

  # Example: "redis.example.com"
  # This creates hostnames like: demo-redis.example.com, ui-redis.example.com
}

#==============================================================================
# DNS CONFIGURATION (for automated Route53 DNS record creation)
#==============================================================================

variable "dns_hosted_zone_id" {
  description = "Route53 hosted zone ID for automatic DNS record creation. If provided, DNS records will be created automatically for ingress endpoints in both regions."
  type        = string
  default     = ""

  # Example: "Z1234567890ABC"
  # Get your hosted zone ID with: aws route53 list-hosted-zones
}

variable "dns_ttl" {
  description = "TTL (in seconds) for DNS records created in Route53"
  type        = number
  default     = 300
}

variable "validate_dns_propagation" {
  description = "Whether to validate DNS propagation after creating records (adds ~30 second delay)"
  type        = bool
  default     = false
}

#==============================================================================
# ACTIVE-ACTIVE (CRDB) CONFIGURATION
#==============================================================================

variable "enable_active_active" {
  description = "Enable Active-Active (CRDB) support by automatically creating RERCs in both regions"
  type        = bool
  default     = true
}

#==============================================================================
# BACKUP CONFIGURATION
#==============================================================================

variable "create_backup_buckets" {
  description = "Create S3 buckets for Redis backups in both regions"
  type        = bool
  default     = true
}

variable "backup_s3_bucket_name_region1" {
  description = "S3 bucket name for Region 1 Redis backups. Leave empty to use <project_prefix>-redis-backups-<region1>."
  type        = string
  default     = ""
}

variable "backup_s3_bucket_name_region2" {
  description = "S3 bucket name for Region 2 Redis backups. Leave empty to use <project_prefix>-redis-backups-<region2>."
  type        = string
  default     = ""
}

variable "backup_s3_prefix" {
  description = "Path prefix inside the backup bucket (for example: backup)"
  type        = string
  default     = "backup"
}

variable "backup_interval" {
  description = "Backup interval in duration format used by the post-deployment script (for example: 24h)"
  type        = string
  default     = "24h"
}

variable "backup_retention_days" {
  description = "Number of days to retain S3 backup objects"
  type        = number
  default     = 7
}

variable "backup_force_destroy" {
  description = "Allow Terraform to destroy the backup bucket even when it contains objects"
  type        = bool
  default     = false
}

#==============================================================================
# REDIS FLEX (optional, shared across both regions)
#==============================================================================

variable "enable_redis_flex" {
  description = "Enable Redis Flex (requires i3/i4i instances)"
  type        = bool
  default     = false
}

#==============================================================================
# BASTION (optional, shared across both regions)
#==============================================================================

variable "create_bastion" {
  description = "Create bastion host for SSH access"
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion"
  type        = string
  default     = "t3.micro"
}

variable "bastion_key_name" {
  description = "SSH key name for bastion"
  type        = string
  default     = ""
}

variable "bastion_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

#==============================================================================
# PROMETHEUS MONITORING CONFIGURATION
#==============================================================================

variable "prometheus_enabled" {
  description = "Enable Prometheus monitoring stack deployment"
  type        = bool
  default     = true
}

variable "prometheus_operator_version" {
  description = "Prometheus Operator version (tag from prometheus-operator/prometheus-operator repo)"
  type        = string
  default     = "v0.70.0"
}

variable "prometheus_replicas" {
  description = "Number of Prometheus replicas for high availability"
  type        = number
  default     = 2
}

variable "prometheus_retention" {
  description = "Prometheus data retention period (e.g., 30d, 7d, 90d)"
  type        = string
  default     = "30d"
}

variable "prometheus_storage_size" {
  description = "Prometheus persistent storage size (e.g., 10Gi, 50Gi, 100Gi)"
  type        = string
  default     = "10Gi"
}

variable "prometheus_cpu_request" {
  description = "Prometheus CPU request (e.g., 500m, 1000m)"
  type        = string
  default     = "500m"
}

variable "prometheus_cpu_limit" {
  description = "Prometheus CPU limit (e.g., 2000m, 4000m)"
  type        = string
  default     = "2000m"
}

variable "prometheus_memory_request" {
  description = "Prometheus memory request (e.g., 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"
}

variable "prometheus_memory_limit" {
  description = "Prometheus memory limit (e.g., 4Gi, 8Gi)"
  type        = string
  default     = "4Gi"
}

variable "prometheus_scrape_interval" {
  description = "Default metrics scrape interval (e.g., 15s, 30s, 60s)"
  type        = string
  default     = "15s"
}

variable "prometheus_scrape_timeout" {
  description = "Scrape timeout (e.g., 10s, 15s)"
  type        = string
  default     = "10s"
}

variable "prometheus_evaluation_interval" {
  description = "Rule evaluation interval (e.g., 15s, 30s)"
  type        = string
  default     = "15s"
}

#==============================================================================
# GRAFANA CONFIGURATION
#==============================================================================

variable "grafana_enabled" {
  description = "Deploy Grafana to Kubernetes cluster (false = use local Grafana on Mac - recommended)"
  type        = bool
  default     = false
}

variable "grafana_admin_password" {
  description = "Grafana admin password (change in production!)"
  type        = string
  sensitive   = true
  default     = "admin123"
}

variable "grafana_replicas" {
  description = "Number of Grafana replicas"
  type        = number
  default     = 1
}

variable "grafana_cpu_request" {
  description = "Grafana CPU request"
  type        = string
  default     = "100m"
}

variable "grafana_cpu_limit" {
  description = "Grafana CPU limit"
  type        = string
  default     = "500m"
}

variable "grafana_memory_request" {
  description = "Grafana memory request"
  type        = string
  default     = "256Mi"
}

variable "grafana_memory_limit" {
  description = "Grafana memory limit"
  type        = string
  default     = "512Mi"
}

#==============================================================================
# SERVICEMONITOR CONFIGURATION
#==============================================================================

variable "redis_metrics_port" {
  description = "Redis Enterprise metrics port"
  type        = number
  default     = 8070
}

variable "redis_metrics_path" {
  description = "Redis Enterprise metrics endpoint path"
  type        = string
  default     = "/v2"
}

variable "redis_metrics_scheme" {
  description = "Redis Enterprise metrics scheme (http or https)"
  type        = string
  default     = "https"
}

#==============================================================================
# ALERT RULES CONFIGURATION
#==============================================================================

variable "alert_redis_memory_threshold" {
  description = "Alert threshold for Redis memory usage (percentage, 0-100)"
  type        = number
  default     = 90
}

variable "alert_redis_cpu_threshold" {
  description = "Alert threshold for Redis CPU usage (percentage, 0-100)"
  type        = number
  default     = 80
}

variable "alert_redis_connection_threshold" {
  description = "Alert threshold for Redis connection count"
  type        = number
  default     = 10000
}
