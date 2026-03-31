#==============================================================================
# External Access - Conditional Load Balancer Module
#==============================================================================
# Provides external access to Redis Enterprise cluster and databases
# Supports multiple load balancer types via conditional module instantiation
#==============================================================================

#==============================================================================
# VALIDATION
#==============================================================================

# Validate that ingress_domain is provided when using NGINX Ingress mode
resource "null_resource" "validate_nginx_config" {
  count = var.external_access_type == "nginx-ingress" && var.ingress_domain == "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo "ERROR: ingress_domain is required when external_access_type = 'nginx-ingress'"
      echo "Please set ingress_domain in your terraform.tfvars (e.g., 'redis.example.com')"
      exit 1
    EOT
  }

  lifecycle {
    precondition {
      condition     = !(var.external_access_type == "nginx-ingress" && var.ingress_domain == "")
      error_message = "ingress_domain is required when external_access_type = 'nginx-ingress'. Set it in terraform.tfvars (e.g., 'redis.example.com')."
    }
  }
}

#==============================================================================
# EXTERNAL ACCESS MODULES
#==============================================================================

# Option 1: AWS Network Load Balancer (NLB)
# Updates Kubernetes services to type LoadBalancer
module "nlb_access" {
  source = "./nlb"
  count  = var.external_access_type == "nlb" ? 1 : 0

  namespace = var.namespace

  # Redis Enterprise UI
  redis_ui_service_name = var.redis_ui_service_name
  expose_ui             = var.expose_redis_ui

  # Redis Enterprise Databases
  redis_db_services = var.redis_db_services
  expose_databases  = var.expose_redis_databases

  tags = var.tags
}

# Option 2: NGINX Ingress Controller
# Deploys NGINX Ingress Controller following Redis Enterprise documentation
# Supports both TLS (production) and non-TLS (testing) modes
module "nginx_ingress_access" {
  source = "./nginx_ingress"
  count  = var.external_access_type == "nginx-ingress" ? 1 : 0

  namespace = var.namespace

  # Redis Enterprise UI
  redis_ui_service_name = var.redis_ui_service_name
  expose_ui             = var.expose_redis_ui

  # Redis Enterprise API (for Active-Active)
  redis_cluster_name = var.redis_cluster_name
  expose_api         = var.expose_redis_api
  api_fqdn           = var.redis_api_fqdn

  # Redis Enterprise Databases
  redis_db_services = var.redis_db_services
  expose_databases  = var.expose_redis_databases

  # NGINX specific configuration
  ingress_domain       = var.ingress_domain
  nginx_instance_count = var.nginx_instance_count
  enable_tls           = var.enable_tls

  tags = var.tags
}

# Option 3: No external access (internal ClusterIP only)
# When external_access_type = "none", no modules are deployed
