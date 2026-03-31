#==============================================================================
# REDIS ENTERPRISE SOFTWARE ON AWS EKS
#==============================================================================
# This configuration deploys a complete Redis Enterprise Software cluster
# on Amazon EKS with:
# - EKS cluster with managed control plane
# - EKS node group with 3+ worker nodes across AZs
# - EBS CSI driver for persistent storage
# - Redis Enterprise operator (via bundle deployment)
# - Redis Enterprise cluster (3-node HA with internal access by default)
# - Optional sample database for testing (1 shard, HA enabled)
#==============================================================================

#==============================================================================
# LOCAL VARIABLES
#==============================================================================

locals {
  name_prefix = "${var.user_prefix}-${var.cluster_name}"

  # Auto-select availability zones if not specified
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}c"
  ]

  # Validate instance types for Redis Flex
  flex_compatible_instances = ["i3.xlarge", "i3.2xlarge", "i3.4xlarge", "i3.8xlarge", "i3.16xlarge",
  "i4i.xlarge", "i4i.2xlarge", "i4i.4xlarge", "i4i.8xlarge", "i4i.16xlarge"]

  using_flex_instance = length([for type in var.node_instance_types : type if contains(local.flex_compatible_instances, type)]) > 0

  tags = merge(
    var.tags,
    {
      Project       = var.project
      Environment   = var.environment
      ClusterName   = var.cluster_name
      owner         = var.owner
      skip_deletion = "yes"
    }
  )
}

#==============================================================================
# VALIDATION: Redis Flex requires i3/i4i instances with NVMe SSDs
#==============================================================================

resource "null_resource" "validate_flex_config" {
  count = var.enable_redis_flex && !local.using_flex_instance ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo "ERROR: Redis Flex (enable_redis_flex=true) requires i3 or i4i instance types with local NVMe SSDs."
      echo "Current instance types: ${join(", ", var.node_instance_types)}"
      echo "Supported instance types: i3.xlarge, i3.2xlarge, i4i.xlarge, i4i.2xlarge, etc."
      exit 1
    EOT
  }

  lifecycle {
    precondition {
      condition     = !var.enable_redis_flex || local.using_flex_instance
      error_message = "Redis Flex requires i3.* or i4i.* instance types with local NVMe SSDs. Current: ${join(", ", var.node_instance_types)}"
    }
  }
}

#==============================================================================
# VPC MODULE
#==============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  cluster_name         = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = local.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = false # Using public subnets for worker nodes

  tags = local.tags
}

#==============================================================================
# EKS CLUSTER MODULE
#==============================================================================

module "eks" {
  source = "./modules/eks_cluster"

  cluster_name                    = local.name_prefix
  kubernetes_version              = var.kubernetes_version
  vpc_id                          = module.vpc.vpc_id
  public_subnet_ids               = module.vpc.public_subnet_ids
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access
  aws_region                      = var.aws_region

  tags = local.tags

  depends_on = [module.vpc]
}

#==============================================================================
# EKS NODE GROUP MODULE
#==============================================================================

module "eks_node_group" {
  source = "./modules/eks_node_group"

  cluster_name              = module.eks.cluster_name
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.public_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  instance_types            = var.node_instance_types
  desired_size              = var.node_desired_size
  min_size                  = var.node_min_size
  max_size                  = var.node_max_size
  disk_size                 = var.node_disk_size

  tags = local.tags

  depends_on = [module.eks]
}

#==============================================================================
# EBS CSI DRIVER MODULE
#==============================================================================

module "ebs_csi_driver" {
  source = "./modules/ebs_csi_driver"

  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_issuer_url    = module.eks.cluster_oidc_issuer_url
  storage_class_name = var.redis_cluster_storage_class
  set_as_default     = true

  tags = local.tags

  depends_on = [module.eks_node_group]
}

#==============================================================================
# LOCAL STORAGE PROVISIONER (for Redis Flex NVMe discovery)
#==============================================================================

module "local_storage_provisioner" {
  source = "./modules/local_storage_provisioner"

  enable_provisioner = var.enable_redis_flex
  cluster_ready      = module.ebs_csi_driver

  # Only deploy if Redis Flex is enabled
  # This discovers and mounts NVMe SSDs on i3/i4i instances
}

#==============================================================================
# REDIS ENTERPRISE OPERATOR MODULE
#==============================================================================

module "redis_operator" {
  source = "./modules/redis_operator"

  namespace        = var.redis_enterprise_namespace
  operator_version = var.redis_operator_version
  cluster_name     = module.eks.cluster_name
  aws_region       = var.aws_region

  depends_on = [module.ebs_csi_driver]
}

#==============================================================================
# REDIS ENTERPRISE CLUSTER MODULE
#==============================================================================

module "redis_cluster" {
  source = "./modules/redis_cluster"

  cluster_name                 = var.cluster_name
  eks_cluster_name             = module.eks.cluster_name
  aws_region                   = var.aws_region
  namespace                    = module.redis_operator.namespace
  operator_ready               = module.redis_operator.operator_ready
  node_count                   = var.redis_cluster_nodes
  admin_username               = var.redis_cluster_username
  admin_password               = var.redis_cluster_password
  node_memory_limit            = var.redis_cluster_memory
  storage_class_name           = module.ebs_csi_driver.storage_class_name
  storage_size                 = var.redis_cluster_storage_size
  redis_enterprise_version_tag = var.redis_enterprise_version_tag

  # Service type configuration
  ui_service_type        = var.ui_internal_lb_enabled ? "LoadBalancer" : var.redis_ui_service_type
  ui_service_annotations = var.ui_internal_lb_enabled ? var.ui_service_annotations : {}
  database_service_type  = var.redis_database_service_type

  # License configuration
  license_secret_name = var.redis_license_secret_name

  # Redis Flex (Auto Tiering) configuration
  enable_redis_flex          = var.enable_redis_flex
  redis_flex_storage_class   = var.redis_flex_storage_class
  redis_flex_flash_disk_size = var.redis_flex_flash_disk_size
  redis_flex_storage_driver  = var.redis_flex_storage_driver

  # Ingress/Route configuration
  enable_ingress      = var.redis_enable_ingress
  api_fqdn_url        = var.redis_api_fqdn_url
  db_fqdn_suffix      = var.redis_db_fqdn_suffix
  ingress_method      = var.redis_ingress_method
  ingress_annotations = var.redis_ingress_annotations

  depends_on = [
    module.redis_operator,
    module.local_storage_provisioner # Ensures NVMe devices are ready for Redis Flex
  ]
}

#==============================================================================
# SAMPLE REDIS DATABASE MODULE
#==============================================================================

module "redis_database" {
  source = "./modules/redis_database"

  create_database = var.create_sample_database
  database_name   = var.sample_db_name
  namespace       = module.redis_operator.namespace
  cluster_name    = module.redis_cluster.cluster_name
  memory_size     = var.sample_db_memory
  database_port   = var.sample_db_port
  replication     = var.sample_db_replication

  # Database password
  database_password = var.sample_db_password

  # TLS configuration
  tls_mode = var.sample_db_tls_mode

  # Service type configuration
  database_service_type = var.sample_db_service_type
  database_service_port = var.sample_db_service_port

  # Advanced database configuration
  shard_count   = var.sample_db_shard_count
  modules_list  = var.sample_db_modules
  redis_version = var.sample_db_redis_version

  # Redis Flex (Auto Tiering) configuration
  enable_redis_flex = var.sample_db_enable_redis_flex
  rof_ram_size      = var.sample_db_rof_ram_size

  cluster_ready = module.redis_cluster

  depends_on = [module.redis_cluster]
}

#==============================================================================
# REDIS TEST CLIENT (Optional)
#==============================================================================
# Deploys a test pod with redis-cli, redis-benchmark, and memtier_benchmark
# for testing connectivity and performance of Redis Enterprise databases
#==============================================================================

module "redis_test_client" {
  source = "./modules/redis_test_client"

  count = var.create_test_client ? 1 : 0

  deployment_name = var.test_client_name
  namespace       = module.redis_operator.namespace

  # Connect to sample database by default
  redis_host     = "${var.sample_db_name}.${module.redis_operator.namespace}.svc.cluster.local"
  redis_port     = var.sample_db_port
  redis_password = var.sample_db_password

  # Resource sizing (t3.micro equivalent: 1 vCPU, 1GB RAM)
  cpu_request    = var.test_client_cpu_request
  cpu_limit      = var.test_client_cpu_limit
  memory_request = var.test_client_memory_request
  memory_limit   = var.test_client_memory_limit

  # Helper test scripts
  create_test_scripts = var.test_client_create_scripts

  # Ensure database is ready first
  redis_cluster_ready = module.redis_database

  depends_on = [module.redis_database]
}

#==============================================================================
# EXTERNAL ACCESS (Optional)
#==============================================================================
# Provides external access to Redis Enterprise cluster and databases
# Supports NLB (now) and NGINX Ingress (Phase 2)
#==============================================================================

module "external_access" {
  source = "./modules/external_access"

  # Only deploy if external access is enabled
  count = var.external_access_type != "none" ? 1 : 0

  external_access_type = var.external_access_type
  namespace            = module.redis_operator.namespace

  # Redis Enterprise UI
  redis_ui_service_name = "${var.cluster_name}-ui"
  expose_redis_ui       = var.expose_redis_ui

  # Redis Enterprise API (for Active-Active)
  # NOTE: When ingressOrRouteSpec is configured in REC, the operator creates Ingresses automatically
  # So we set expose_redis_api = false to avoid duplicate Ingress creation by Terraform
  redis_cluster_name = var.cluster_name
  expose_redis_api   = false  # Operator manages API Ingress via ingressOrRouteSpec
  redis_api_fqdn     = var.redis_api_fqdn_url

  # Redis Enterprise Databases
  redis_db_services = var.create_sample_database ? {
    "${var.sample_db_name}" = {
      port         = var.sample_db_port
      service_name = var.sample_db_name
    }
  } : {}
  expose_redis_databases = var.expose_redis_databases

  # NGINX Ingress settings
  ingress_domain       = var.ingress_domain
  nginx_instance_count = var.nginx_instance_count
  enable_tls           = var.enable_tls

  tags = local.tags

  depends_on = [module.redis_cluster, module.redis_database]
}

#==============================================================================
# DNS MODULE (Optional - for Route53 DNS automation)
#==============================================================================
# Automatically creates Route53 DNS records for Redis Enterprise ingress
# Required for Active-Active (CRDB) databases
#==============================================================================

module "dns" {
  source = "./modules/dns"

  count = var.create_dns_records ? 1 : 0

  create_dns_records    = var.create_dns_records
  dns_hosted_zone_id    = var.dns_hosted_zone_id
  api_fqdn              = var.redis_api_fqdn_url
  db_wildcard_fqdn      = "*${var.redis_db_fqdn_suffix}"
  db_fqdn_suffix        = var.redis_db_fqdn_suffix
  loadbalancer_dns_name = module.external_access[0].nginx_ingress_dns
  dns_ttl               = var.dns_ttl
  validate_dns          = var.validate_dns_propagation

  depends_on = [module.external_access]
}

#==============================================================================
# EC2 BASTION (Optional)
#==============================================================================
# EC2 bastion instance for Redis testing, troubleshooting, and admin tasks
# Includes: redis-cli, memtier_benchmark, kubectl, AWS CLI
#==============================================================================

module "bastion" {
  source = "../../../modules/ec2_bastion"

  # Only deploy if bastion is enabled
  count = var.create_bastion ? 1 : 0

  name_prefix = var.user_prefix
  owner       = var.owner
  project     = "redis-enterprise-eks"

  # Networking - deploy in public subnet for external access
  vpc_id                  = module.vpc.vpc_id
  subnet_id               = module.vpc.public_subnet_ids[0]
  key_name                = var.ec2_key_name
  ssh_private_key_path    = var.ssh_private_key_path
  associate_public_ip     = var.bastion_associate_public_ip
  ssh_cidr_blocks         = var.bastion_ssh_cidr_blocks
  instance_type           = var.bastion_instance_type

  # Install kubectl and AWS CLI for EKS management
  install_kubectl = true
  install_aws_cli = true
  install_docker  = var.bastion_install_docker

  # EKS cluster configuration
  eks_cluster_name = module.eks.cluster_name
  aws_region       = var.aws_region

  # Redis endpoints for testing (using internal service endpoint)
  redis_endpoints = var.create_sample_database ? {
    "${var.sample_db_name}" = {
      endpoint = "${var.sample_db_name}.${module.redis_operator.namespace}.svc.cluster.local:${var.sample_db_port}"
      password = var.sample_db_password
    }
  } : {}

  tags = local.tags

  depends_on = [module.eks, module.redis_database, module.external_access]
}

#==============================================================================
# REDIS ENTERPRISE REMOTE CLUSTER (RERC) MANAGEMENT
#==============================================================================
# Creates RERCs for Active-Active (CRDB) replication across regions
# Uses Route53 FQDNs for both API and database endpoints (required for SSL Passthrough)
#==============================================================================

module "rerc_management" {
  source = "./modules/rerc_management"

  count = var.enable_active_active ? 1 : 0

  namespace = module.redis_operator.namespace

  # Local RERC (always created when Active-Active is enabled)
  create_local_rerc     = true
  local_cluster_name    = var.cluster_name
  local_api_fqdn        = var.local_api_fqdn
  local_db_fqdn_suffix  = var.local_db_fqdn_suffix

  # Remote RERC (created only if remote cluster is specified)
  create_remote_rerc    = var.remote_cluster_name != ""
  remote_cluster_name   = var.remote_cluster_name
  remote_api_fqdn       = var.remote_api_fqdn
  remote_db_fqdn_suffix = var.remote_db_fqdn_suffix

  # Ensure cluster is ready before creating RERCs
  cluster_ready = module.redis_cluster.cluster_ready

  depends_on = [module.redis_cluster, module.external_access]
}
