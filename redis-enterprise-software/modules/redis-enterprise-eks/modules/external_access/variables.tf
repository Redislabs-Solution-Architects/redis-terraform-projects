#==============================================================================
# External Access - Variables
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

variable "namespace" {
  description = "Kubernetes namespace for Redis Enterprise"
  type        = string
}

# Redis Enterprise UI Configuration
variable "redis_ui_service_name" {
  description = "Name of the Redis Enterprise UI service"
  type        = string
}

variable "expose_redis_ui" {
  description = "Expose Redis Enterprise UI externally"
  type        = bool
  default     = false
}

# Redis Enterprise API Configuration (for Active-Active)
variable "redis_cluster_name" {
  description = "Name of the Redis Enterprise cluster (for API service name)"
  type        = string
  default     = ""
}

variable "expose_redis_api" {
  description = "Expose Redis Enterprise API externally (required for Active-Active)"
  type        = bool
  default     = false
}

variable "redis_api_fqdn" {
  description = "Fully qualified domain name for Redis Enterprise API (e.g., api.region1.redis.example.com)"
  type        = string
  default     = ""
}

# Redis Enterprise Database Configuration
variable "redis_db_services" {
  description = "Map of Redis databases to expose externally (database_name => {port, service_name})"
  type = map(object({
    port         = number
    service_name = string
  }))
  default = {}
}

variable "expose_redis_databases" {
  description = "Expose Redis databases externally"
  type        = bool
  default     = false
}

# NGINX Ingress specific variables (for future use)
variable "ingress_domain" {
  description = "Base domain for NGINX ingress (e.g., redis.example.com)"
  type        = string
  default     = ""
}

variable "nginx_instance_count" {
  description = "Number of NGINX ingress controller replicas"
  type        = number
  default     = 2
}

variable "enable_tls" {
  description = "Enable TLS mode for NGINX Ingress (production). When true, requires TLS on Redis databases and uses SSL passthrough. When false (testing), uses direct port access."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
