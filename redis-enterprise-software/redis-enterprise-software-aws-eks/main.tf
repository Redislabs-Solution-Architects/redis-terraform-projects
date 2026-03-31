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

  tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ClusterName = var.cluster_name
    }
  )
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

  # Ingress/Route configuration
  enable_ingress      = var.redis_enable_ingress
  api_fqdn_url        = var.redis_api_fqdn_url
  db_fqdn_suffix      = var.redis_db_fqdn_suffix
  ingress_method      = var.redis_ingress_method
  ingress_annotations = var.redis_ingress_annotations

  depends_on = [module.redis_operator]
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

  # Service type configuration
  database_service_type = var.sample_db_service_type
  database_service_port = var.sample_db_service_port

  # Advanced database configuration
  shard_count   = var.sample_db_shard_count
  modules_list  = var.sample_db_modules
  redis_version = var.sample_db_redis_version

  cluster_ready = module.redis_cluster

  depends_on = [module.redis_cluster]
}
