#==============================================================================
# NGINX Ingress External Access - Variables
#==============================================================================

variable "namespace" {
  description = "Kubernetes namespace for Redis Enterprise"
  type        = string
}

variable "redis_ui_service_name" {
  description = "Name of the Redis Enterprise UI service"
  type        = string
}

variable "expose_ui" {
  description = "Expose Redis Enterprise UI externally via NGINX Ingress"
  type        = bool
  default     = false
}

variable "expose_api" {
  description = "Expose Redis Enterprise API externally via NGINX Ingress (required for Active-Active)"
  type        = bool
  default     = false
}

variable "redis_cluster_name" {
  description = "Name of the Redis Enterprise cluster (for API service name)"
  type        = string
  default     = ""
}

variable "api_fqdn" {
  description = "Fully qualified domain name for Redis Enterprise API (e.g., api.region1.redis.example.com)"
  type        = string
  default     = ""
}

variable "redis_db_services" {
  description = "Map of Redis databases to expose externally"
  type = map(object({
    port         = number
    service_name = string
  }))
  default = {}
}

variable "expose_databases" {
  description = "Expose Redis databases externally via NGINX Ingress"
  type        = bool
  default     = false
}

variable "ingress_domain" {
  description = "Base domain for NGINX ingress (e.g., redis.example.com). Required for NGINX Ingress mode."
  type        = string
  default     = ""
}

variable "nginx_instance_count" {
  description = "Number of NGINX ingress controller replicas for high availability"
  type        = number
  default     = 2
}

variable "enable_tls" {
  description = "Enable TLS mode (production). When true, requires TLS on Redis databases and uses SSL passthrough. When false (testing), uses direct port access."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
