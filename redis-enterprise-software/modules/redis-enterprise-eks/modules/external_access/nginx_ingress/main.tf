#==============================================================================
# NGINX INGRESS EXTERNAL ACCESS
#==============================================================================
# Implements external access following Redis Enterprise official documentation:
# https://redis.io/docs/latest/operate/kubernetes/networking/ingress/
#
# Supports two modes:
# - TLS Mode (production): SSL passthrough on port 443, requires TLS on databases
# - Non-TLS Mode (testing): Direct port access without TLS
#==============================================================================

#==============================================================================
# NGINX INGRESS CONTROLLER
#==============================================================================
# Deploys NGINX Ingress Controller via official Helm chart
# Creates AWS NLB for ingress (single NLB for all services)
#==============================================================================

resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3" # Latest stable version
  namespace        = "ingress-nginx"
  create_namespace = true

  # Configure for AWS EKS with NLB
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # Enable SSL passthrough for TLS mode (required per Redis docs)
  set {
    name  = "controller.extraArgs.enable-ssl-passthrough"
    value = ""
  }

  # High availability configuration
  set {
    name  = "controller.replicaCount"
    value = tostring(var.nginx_instance_count)
  }

  # Configure TCP services ConfigMap for non-TLS mode
  dynamic "set" {
    for_each = var.expose_databases && !var.enable_tls ? [1] : []
    content {
      name  = "controller.extraArgs.tcp-services-configmap"
      value = "ingress-nginx/tcp-services"
    }
  }

  # Wait for deployment to be ready
  wait    = true
  timeout = 600
}

#==============================================================================
# REDIS ENTERPRISE UI INGRESS (TLS MODE)
#==============================================================================
# Exposes Redis Enterprise UI via NGINX Ingress with SSL passthrough
# Only created when TLS mode is enabled and expose_ui is true
#==============================================================================

resource "kubernetes_ingress_v1" "redis_ui_tls" {
  count = var.expose_ui && var.enable_tls ? 1 : 0

  metadata {
    name      = "${var.redis_ui_service_name}-ingress"
    namespace = var.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/ssl-passthrough"  = "true"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "ui-${var.ingress_domain}"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = var.redis_ui_service_name
              port {
                number = 8443
              }
            }
          }
        }
      }
    }

    tls {
      hosts = ["ui-${var.ingress_domain}"]
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# REDIS ENTERPRISE UI INGRESS (NON-TLS MODE - TESTING)
#==============================================================================
# Exposes Redis Enterprise UI without TLS for testing purposes
# Only created when TLS mode is disabled and expose_ui is true
#==============================================================================

resource "kubernetes_ingress_v1" "redis_ui_non_tls" {
  count = var.expose_ui && !var.enable_tls ? 1 : 0

  metadata {
    name      = "${var.redis_ui_service_name}-ingress"
    namespace = var.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "ui-${var.ingress_domain}"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = var.redis_ui_service_name
              port {
                number = 8443
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# REDIS ENTERPRISE API INGRESS (TLS MODE)
#==============================================================================
# Exposes Redis Enterprise API (port 9443) via NGINX Ingress with SSL passthrough
# Required for Active-Active (CRDB) cross-region communication
# Only created when TLS mode is enabled and expose_api is true
#==============================================================================

resource "kubernetes_ingress_v1" "redis_api_tls" {
  count = var.expose_api && var.enable_tls ? 1 : 0

  metadata {
    name      = "${var.redis_cluster_name}-api-ingress"
    namespace = var.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/ssl-passthrough"  = "true"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.api_fqdn

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "${var.redis_cluster_name}"
              port {
                number = 9443
              }
            }
          }
        }
      }
    }

    tls {
      hosts = [var.api_fqdn]
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# REDIS ENTERPRISE API INGRESS (NON-TLS MODE)
#==============================================================================
# Exposes Redis Enterprise API without TLS termination at ingress
# SSL passthrough is used - NGINX forwards encrypted traffic to Redis Enterprise
# The host field is required for proper routing and DNS resolution
#==============================================================================

resource "kubernetes_ingress_v1" "redis_api_non_tls" {
  count = var.expose_api && !var.enable_tls ? 1 : 0

  metadata {
    name      = "${var.redis_cluster_name}-api-ingress"
    namespace = var.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
      "nginx.ingress.kubernetes.io/ssl-passthrough"  = "true"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.api_fqdn
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "${var.redis_cluster_name}"
              port {
                number = 9443
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# REDIS DATABASE SERVICES (TLS MODE)
#==============================================================================
# Updates database services to use standard port 443 with "redis" port name
# Required per Redis documentation for Ingress with TLS
# Only created when TLS mode is enabled
#==============================================================================

resource "kubernetes_service_v1" "redis_db_tls" {
  for_each = var.expose_databases && var.enable_tls ? var.redis_db_services : {}

  metadata {
    name      = "${each.value.service_name}-external"
    namespace = var.namespace
  }

  spec {
    type = "ClusterIP"

    selector = {
      "redis.io/database" = each.key
    }

    port {
      name        = "redis"         # Required port name per Redis docs
      port        = 443             # External port (standard TLS port)
      target_port = each.value.port # Actual database port (e.g., 12000)
      protocol    = "TCP"
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# REDIS DATABASE INGRESS (TLS MODE)
#==============================================================================
# Creates Ingress resources for each Redis database with SSL passthrough
# Follows Redis Enterprise documentation requirements:
# - SSL passthrough annotation
# - Port 443 for external access
# - Port name "redis"
# - SNI support via hostname-based routing
#==============================================================================

resource "kubernetes_ingress_v1" "redis_db_tls" {
  for_each = var.expose_databases && var.enable_tls ? var.redis_db_services : {}

  metadata {
    name      = "${each.value.service_name}-ingress"
    namespace = var.namespace

    annotations = {
      "nginx.ingress.kubernetes.io/ssl-passthrough"  = "true"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "${each.key}-${var.ingress_domain}"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "${each.value.service_name}-external"
              port {
                name = "redis"
              }
            }
          }
        }
      }
    }

    tls {
      hosts = ["${each.key}-${var.ingress_domain}"]
    }
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_service_v1.redis_db_tls
  ]
}

#==============================================================================
# TCP CONFIGMAP FOR NON-TLS MODE (TESTING)
#==============================================================================
# Configures NGINX to forward TCP traffic directly to database ports
# Used for testing without TLS
# Maps external ports to internal database services
#
# EXTERNAL ACCESS FOR MANUALLY CREATED DATABASES:
# ------------------------------------------------
# Terraform-managed databases are automatically configured for external access.
# For databases created manually via kubectl, you need TWO simple commands:
#
# 1. Update TCP ConfigMap (tells NGINX where to route traffic):
#    kubectl patch configmap tcp-services -n ingress-nginx \
#      --type merge \
#      -p '{"data":{"<PORT>":"redis-enterprise/<SERVICE-NAME>:<PORT>"}}'
#
# 2. Expose port on NLB (opens port on LoadBalancer):
#    kubectl patch svc ingress-nginx-controller -n ingress-nginx \
#      --type='json' \
#      -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "redis-<PORT>", "port": <PORT>, "protocol": "TCP", "targetPort": <PORT>}}]'
#
# Example for database on port 15000:
#    kubectl patch configmap tcp-services -n ingress-nginx \
#      --type merge \
#      -p '{"data":{"15000":"redis-enterprise/my-db:15000"}}'
#
#    kubectl patch svc ingress-nginx-controller -n ingress-nginx \
#      --type='json' \
#      -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "redis-15000", "port": 15000, "protocol": "TCP", "targetPort": 15000}}]'
#
# That's it! Your database is now accessible externally via the NLB.
#==============================================================================

resource "kubernetes_config_map_v1" "tcp_services" {
  count = var.expose_databases && !var.enable_tls ? 1 : 0

  metadata {
    name      = "tcp-services"
    namespace = "ingress-nginx"
  }

  data = {
    for db_name, db_config in var.redis_db_services :
    "${db_config.port}" => "${var.namespace}/${db_config.service_name}:${db_config.port}"
  }

  depends_on = [helm_release.nginx_ingress]
}

#==============================================================================
# UPDATE NGINX CONTROLLER TO USE TCP CONFIGMAP (NON-TLS MODE)
#==============================================================================
# Patches the NGINX controller to load the TCP ConfigMap
# Only applied when non-TLS mode is used
#==============================================================================

resource "null_resource" "update_nginx_tcp_config" {
  count = var.expose_databases && !var.enable_tls ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      kubectl patch deployment ingress-nginx-controller \
        -n ingress-nginx \
        --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--tcp-services-configmap=ingress-nginx/tcp-services"}]' \
        || true
    EOT
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_config_map_v1.tcp_services
  ]
}

#==============================================================================
# EXPOSE REDIS DATABASE PORTS ON NGINX SERVICE (NON-TLS MODE)
#==============================================================================
# Exposes only the specific ports for Terraform-managed databases on the NLB
#
# DESIGN DECISION: On-Demand Port Exposure
# ----------------------------------------
# We only expose ports for databases managed by Terraform rather than
# pre-exposing the entire Redis Enterprise port range (10000-19999).
#
# Benefits:
# - Fast deployment (seconds vs 10+ minutes for 10,000 ports)
# - Only exposes necessary ports (better security)
# - Simple pattern that users can follow for manually created databases
#
# FOR MANUALLY CREATED DATABASES:
# When you create a database manually via kubectl, expose its port with:
#
# 1. Update TCP ConfigMap:
#    kubectl patch configmap tcp-services -n ingress-nginx \
#      --type merge \
#      -p '{"data":{"<PORT>":"redis-enterprise/<SERVICE-NAME>:<PORT>"}}'
#
# 2. Expose port on NLB:
#    kubectl patch svc ingress-nginx-controller -n ingress-nginx \
#      --type='json' \
#      -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "redis-<PORT>", "port": <PORT>, "protocol": "TCP", "targetPort": <PORT>}}]'
#
# Example for database on port 15000:
#    kubectl patch configmap tcp-services -n ingress-nginx \
#      --type merge \
#      -p '{"data":{"15000":"redis-enterprise/my-db:15000"}}'
#
#    kubectl patch svc ingress-nginx-controller -n ingress-nginx \
#      --type='json' \
#      -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "redis-15000", "port": 15000, "protocol": "TCP", "targetPort": 15000}}]'
#
# That's it! Two simple commands.
#==============================================================================

resource "null_resource" "expose_database_ports" {
  for_each = var.expose_databases && !var.enable_tls ? var.redis_db_services : {}

  provisioner "local-exec" {
    command = <<-EOT
      set -e  # Exit on any error

      echo "Exposing port ${each.value.port} for database ${each.key} on NGINX Ingress NLB..."

      # Check if port already exists
      EXISTING_PORTS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")

      if echo "$EXISTING_PORTS" | grep -q "\b${each.value.port}\b"; then
        echo "Port ${each.value.port} already exposed on NLB service"
      else
        echo "Adding port ${each.value.port} to NLB service..."
        kubectl patch svc ingress-nginx-controller \
          -n ingress-nginx \
          --type='json' \
          -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "redis-${each.value.port}", "port": ${each.value.port}, "protocol": "TCP", "targetPort": ${each.value.port}}}]'

        # Verify port was added
        sleep 2
        VERIFY_PORTS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[*].port}')

        if echo "$VERIFY_PORTS" | grep -q "\b${each.value.port}\b"; then
          echo "✓ Successfully exposed port ${each.value.port} on NLB service"
        else
          echo "ERROR: Port ${each.value.port} was not added to NLB service"
          echo "Current ports: $VERIFY_PORTS"
          exit 1
        fi
      fi
    EOT
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_config_map_v1.tcp_services,
    null_resource.update_nginx_tcp_config
  ]

  # Force recreation if port changes or if service state changes
  triggers = {
    port            = each.value.port
    service_name    = each.value.service_name
    configmap_hash  = md5(jsonencode(kubernetes_config_map_v1.tcp_services[0].data))
  }
}
