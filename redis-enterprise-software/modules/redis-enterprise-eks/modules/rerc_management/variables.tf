#==============================================================================
# RERC MANAGEMENT MODULE VARIABLES
#==============================================================================

variable "namespace" {
  description = "Kubernetes namespace for Redis Enterprise"
  type        = string
  default     = "redis-enterprise"
}

variable "cluster_ready" {
  description = "Dependency to ensure cluster is ready before creating RERCs"
  type        = any
  default     = null
}

#==============================================================================
# LOCAL RERC CONFIGURATION
#==============================================================================

variable "create_local_rerc" {
  description = "Whether to create the local RERC (points to local cluster)"
  type        = bool
  default     = true
}

variable "local_cluster_name" {
  description = "Name of the local Redis Enterprise Cluster"
  type        = string
}

variable "local_api_fqdn" {
  description = "Route53 FQDN for local cluster API (e.g., api.region1.redis.local)"
  type        = string
}

variable "local_db_fqdn_suffix" {
  description = "Route53 FQDN suffix for local cluster databases (e.g., .db.region1.redis.local)"
  type        = string
}

#==============================================================================
# REMOTE RERC CONFIGURATION
#==============================================================================

variable "create_remote_rerc" {
  description = "Whether to create the remote RERC (points to remote cluster)"
  type        = bool
  default     = false
}

variable "remote_cluster_name" {
  description = "Name of the remote Redis Enterprise Cluster"
  type        = string
  default     = ""
}

variable "remote_api_fqdn" {
  description = "Route53 FQDN for remote cluster API (e.g., api.region2.redis.local)"
  type        = string
  default     = ""
}

variable "remote_db_fqdn_suffix" {
  description = "Route53 FQDN suffix for remote cluster databases (e.g., .db.region2.redis.local)"
  type        = string
  default     = ""
}

