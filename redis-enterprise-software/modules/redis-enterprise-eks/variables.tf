#==============================================================================
# PROJECT IDENTIFICATION
#==============================================================================

variable "project" {
  description = "Project name for resource naming and tagging"
  type        = string
  default     = "redis-enterprise-eks"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner name for resource tagging"
  type        = string
}

variable "user_prefix" {
  description = "User prefix for unique resource naming"
  type        = string
}

variable "cluster_name" {
  description = "Redis Enterprise cluster name"
  type        = string
  default     = "redis-ent-eks"
}

#==============================================================================
# AWS CONFIGURATION
#==============================================================================

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "availability_zones" {
  description = "List of availability zones to use. If empty, will auto-select based on region"
  type        = list(string)
  default     = []
}

#==============================================================================
# NETWORK CONFIGURATION
#==============================================================================

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

#==============================================================================
# EKS CLUSTER CONFIGURATION
#==============================================================================

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.33"
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to EKS cluster endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Enable private access to EKS cluster endpoint"
  type        = bool
  default     = true
}

#==============================================================================
# EKS NODE GROUP CONFIGURATION
#==============================================================================

variable "node_instance_types" {
  description = "EC2 instance types for EKS worker nodes"
  type        = list(string)
  default     = ["t3.xlarge"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3
  validation {
    condition     = var.node_desired_size >= 3
    error_message = "Redis Enterprise requires minimum 3 worker nodes for high availability."
  }
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3
  validation {
    condition     = var.node_min_size >= 3
    error_message = "Redis Enterprise requires minimum 3 worker nodes for high availability."
  }
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 100
}

#==============================================================================
# REDIS ENTERPRISE CONFIGURATION
#==============================================================================

variable "redis_enterprise_namespace" {
  description = "Kubernetes namespace for Redis Enterprise"
  type        = string
  default     = "redis-enterprise"
}

variable "redis_operator_version" {
  description = "Redis Enterprise operator version (Helm chart version)"
  type        = string
  default     = "v7.4.6-2"
}

variable "redis_cluster_nodes" {
  description = "Number of Redis Enterprise cluster nodes"
  type        = number
  default     = 3
  validation {
    condition     = var.redis_cluster_nodes >= 3
    error_message = "Redis Enterprise cluster requires minimum 3 nodes for high availability."
  }
}

variable "redis_cluster_username" {
  description = "Redis Enterprise cluster admin username (email format)"
  type        = string
  default     = "admin@admin.com"
  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.redis_cluster_username))
    error_message = "Username must be in email format."
  }
}

variable "redis_cluster_password" {
  description = "Redis Enterprise cluster admin password (alphanumeric only)"
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[a-zA-Z0-9]+$", var.redis_cluster_password))
    error_message = "Password must be alphanumeric (letters and numbers only)."
  }
}

variable "redis_cluster_memory" {
  description = "Memory limit for each Redis Enterprise node (e.g., '4Gi', '8Gi')"
  type        = string
  default     = "4Gi"
}

variable "redis_cluster_storage_size" {
  description = "Persistent storage size for each Redis Enterprise node (e.g., '50Gi', '100Gi')"
  type        = string
  default     = "50Gi"
}

variable "redis_cluster_storage_class" {
  description = "Storage class for Redis Enterprise persistent volumes"
  type        = string
  default     = "gp3"
}

variable "redis_enterprise_version_tag" {
  description = "Redis Enterprise image tag (e.g., 7.4.6-xx) matching the operator"
  type        = string
  default     = "7.4.6-22"
}

#==============================================================================
# REDIS FLEX (AUTO TIERING) CONFIGURATION
#==============================================================================

variable "enable_redis_flex" {
  description = "Enable Redis Flex (Auto Tiering) for flash storage. Requires local NVMe SSDs on worker nodes."
  type        = bool
  default     = false
}

variable "redis_flex_storage_class" {
  description = "Storage class for Redis Flex flash storage (must be local NVMe SSDs, not EBS)"
  type        = string
  default     = "local-scsi"
}

variable "redis_flex_flash_disk_size" {
  description = "Flash disk size per node for Redis Flex (e.g., '100G', '500G')"
  type        = string
  default     = "100G"
}

variable "redis_flex_storage_driver" {
  description = "Storage driver for Redis Flex: 'speedb' (default) or 'rocksdb'"
  type        = string
  default     = "speedb"
  validation {
    condition     = contains(["speedb", "rocksdb"], var.redis_flex_storage_driver)
    error_message = "Storage driver must be either 'speedb' or 'rocksdb'."
  }
}

variable "sample_db_enable_redis_flex" {
  description = "Enable Redis Flex for sample database (requires enable_redis_flex=true at cluster level)"
  type        = bool
  default     = false
}

variable "sample_db_rof_ram_size" {
  description = "RAM size for Redis Flex database (minimum 10% of sample_db_memory, e.g., '10GB')"
  type        = string
  default     = "10GB"
}

#==============================================================================
# REDIS UI AND DATABASE SERVICE CONFIGURATION
#==============================================================================

variable "redis_ui_service_type" {
  description = "Service type for Redis Enterprise UI (ClusterIP for internal, LoadBalancer for external)"
  type        = string
  default     = "ClusterIP"
}

variable "ui_internal_lb_enabled" {
  description = "If true, exposes the UI via an internal AWS LoadBalancer (kept inside the VPC); otherwise uses ClusterIP."
  type        = bool
  default     = false
}

variable "ui_service_annotations" {
  description = "Annotations to apply to the UI service (used when enabling an internal LB)."
  type        = map(string)
  default = {
    "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
  }
}

variable "redis_database_service_type" {
  description = "Default service type for databases (ClusterIP for internal, LoadBalancer for external)"
  type        = string
  default     = "ClusterIP"
}

variable "redis_license_secret_name" {
  description = "Name of Kubernetes secret containing Redis Enterprise license (optional)"
  type        = string
  default     = ""
}

#==============================================================================
# REDIS INGRESS CONFIGURATION (for external access)
#==============================================================================

variable "redis_enable_ingress" {
  description = "Enable ingress/route configuration for external access"
  type        = bool
  default     = false
}

variable "redis_api_fqdn_url" {
  description = "FQDN for Redis Enterprise API (required if redis_enable_ingress is true)"
  type        = string
  default     = ""
}

variable "redis_db_fqdn_suffix" {
  description = "FQDN suffix for database access (required if redis_enable_ingress is true)"
  type        = string
  default     = ""
}

variable "redis_ingress_method" {
  description = "Ingress method: 'ingress' for NGINX/HAProxy or 'openShiftRoute'"
  type        = string
  default     = "ingress"
}

variable "redis_ingress_annotations" {
  description = "Annotations for ingress controller"
  type        = map(string)
  default = {
    "kubernetes.io/ingress.class"                 = "nginx"
    "nginx.ingress.kubernetes.io/ssl-passthrough" = "true"
  }
}

#==============================================================================
# SAMPLE DATABASE CONFIGURATION
#==============================================================================

variable "create_sample_database" {
  description = "Create a sample Redis database for testing"
  type        = bool
  default     = true
}

variable "sample_db_name" {
  description = "Name for the sample Redis database"
  type        = string
  default     = "demo"
}

variable "sample_db_memory" {
  description = "Memory size for sample database (e.g., '100MB', '1GB')"
  type        = string
  default     = "100MB"
}

variable "sample_db_port" {
  description = "Port for sample database (10000-19999)"
  type        = number
  default     = 12000
  validation {
    condition     = var.sample_db_port >= 10000 && var.sample_db_port <= 19999
    error_message = "Database port must be between 10000 and 19999."
  }
}

variable "sample_db_replication" {
  description = "Enable replication for sample database (HA enabled by default)"
  type        = bool
  default     = true
}

variable "sample_db_service_type" {
  description = "Service type for sample database (ClusterIP for internal, LoadBalancer for external)"
  type        = string
  default     = "ClusterIP"
}

variable "sample_db_service_port" {
  description = "Custom service port for external access (0 to use database_port)"
  type        = number
  default     = 0
}

variable "sample_db_shard_count" {
  description = "Number of shards for sample database (1 for single shard)"
  type        = number
  default     = 1
}

variable "sample_db_modules" {
  description = "List of Redis modules to enable (e.g., [{name = 'RedisJSON', version = '2.6.6'}])"
  type = list(object({
    name    = string
    version = string
  }))
  default = []
}

variable "sample_db_redis_version" {
  description = "Redis OSS version for sample database (empty for cluster default)"
  type        = string
  default     = ""
}

variable "sample_db_password" {
  description = "Password for sample database (empty for no password)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sample_db_tls_mode" {
  description = "TLS mode for sample database: 'disabled', 'enabled', or 'replica_ssl'. Required to be 'enabled' when using NGINX Ingress with enable_tls=true."
  type        = string
  default     = "disabled"
  validation {
    condition     = contains(["disabled", "enabled", "replica_ssl"], var.sample_db_tls_mode)
    error_message = "TLS mode must be one of: disabled, enabled, replica_ssl."
  }
}

#==============================================================================
# REDIS TEST CLIENT CONFIGURATION
#==============================================================================

variable "create_test_client" {
  description = "Create a test client pod with redis-cli, redis-benchmark, and memtier_benchmark"
  type        = bool
  default     = false
}

variable "test_client_name" {
  description = "Name of the test client deployment"
  type        = string
  default     = "redis-test-client"
}

variable "test_client_cpu_request" {
  description = "CPU request for test client (t3.micro = 500m)"
  type        = string
  default     = "500m"
}

variable "test_client_cpu_limit" {
  description = "CPU limit for test client (t3.micro = 1000m = 1 vCPU)"
  type        = string
  default     = "1000m"
}

variable "test_client_memory_request" {
  description = "Memory request for test client (t3.micro = 512Mi)"
  type        = string
  default     = "512Mi"
}

variable "test_client_memory_limit" {
  description = "Memory limit for test client (t3.micro = 1Gi = 1GB RAM)"
  type        = string
  default     = "1Gi"
}

variable "test_client_create_scripts" {
  description = "Create ConfigMap with helper test scripts"
  type        = bool
  default     = true
}

#==============================================================================
# EXTERNAL ACCESS CONFIGURATION
#==============================================================================

variable "external_access_type" {
  description = "Type of external access: 'nlb' (AWS Network Load Balancer), 'nginx-ingress' (NGINX Ingress Controller), or 'none' (internal only)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["nlb", "nginx-ingress", "none"], var.external_access_type)
    error_message = "External access type must be 'nlb', 'nginx-ingress', or 'none'."
  }
}

variable "expose_redis_ui" {
  description = "Expose Redis Enterprise UI externally (requires external_access_type != 'none')"
  type        = bool
  default     = false
}

variable "expose_redis_databases" {
  description = "Expose Redis databases externally (requires external_access_type != 'none')"
  type        = bool
  default     = false
}

# NGINX Ingress specific variables
variable "ingress_domain" {
  description = "Base domain for NGINX ingress when using nginx-ingress mode (e.g., redis.example.com)"
  type        = string
  default     = ""
}

#==============================================================================
# DNS CONFIGURATION (for automated Route53 DNS record creation)
#==============================================================================

variable "dns_hosted_zone_id" {
  description = "Route53 hosted zone ID for automatic DNS record creation. If provided, DNS records will be created automatically for ingress endpoints."
  type        = string
  default     = ""
}

variable "create_dns_records" {
  description = "Whether to create Route53 DNS records for ingress endpoints."
  type        = bool
  default     = false
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

variable "nginx_instance_count" {
  description = "Number of NGINX ingress controller replicas (only used with nginx-ingress mode)"
  type        = number
  default     = 2
}

variable "enable_tls" {
  description = "Enable TLS mode for NGINX Ingress (production). When true, requires TLS on Redis databases and uses SSL passthrough on port 443. When false (testing), uses direct port access without TLS."
  type        = bool
  default     = false
}

#==============================================================================
# EC2 BASTION CONFIGURATION
#==============================================================================

variable "create_bastion" {
  description = "Create EC2 bastion instance for Redis testing, troubleshooting, and admin tasks"
  type        = bool
  default     = false
}

variable "ec2_key_name" {
  description = "SSH key pair name for EC2 bastion instance (must exist in AWS region)"
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key file for bastion access"
  type        = string
  default     = ""
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion host"
  type        = string
  default     = "t3.small"
}

variable "bastion_associate_public_ip" {
  description = "Associate public IP address with bastion instance"
  type        = bool
  default     = true
}

variable "bastion_ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to bastion instance (0.0.0.0/0 = anywhere, restrict in production)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "bastion_install_docker" {
  description = "Install Docker on bastion instance for container operations"
  type        = bool
  default     = false
}

#==============================================================================
# RESOURCE TAGGING
#==============================================================================

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

#==============================================================================
# ACTIVE-ACTIVE (RERC) CONFIGURATION
#==============================================================================

variable "enable_active_active" {
  description = "Enable Active-Active (CRDB) support by creating RERCs"
  type        = bool
  default     = false
}

variable "local_api_fqdn" {
  description = "Route53 FQDN for local cluster API (e.g., api.region1.redis.local). Required for Active-Active."
  type        = string
  default     = ""
}

variable "local_db_fqdn_suffix" {
  description = "Route53 FQDN suffix for local cluster databases (e.g., .db.region1.redis.local). Required for Active-Active."
  type        = string
  default     = ""
}

variable "remote_cluster_name" {
  description = "Name of the remote Redis Enterprise Cluster for Active-Active replication"
  type        = string
  default     = ""
}

variable "remote_api_fqdn" {
  description = "Route53 FQDN for remote cluster API (e.g., api.region2.redis.local). Required for Active-Active."
  type        = string
  default     = ""
}

variable "remote_db_fqdn_suffix" {
  description = "Route53 FQDN suffix for remote cluster databases (e.g., .db.region2.redis.local). Required for Active-Active."
  type        = string
  default     = ""
}
