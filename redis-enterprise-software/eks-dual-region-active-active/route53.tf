#==============================================================================
# ROUTE53 PRIVATE HOSTED ZONE FOR ACTIVE-ACTIVE DNS
#==============================================================================
# This creates a private hosted zone for redis.local and associates it with
# both VPCs so that pods in both regions can resolve the API FQDNs

# Only create if dns_hosted_zone_id is not provided
locals {
  create_route53_zone = var.dns_hosted_zone_id == ""
  effective_zone_id   = local.create_route53_zone ? aws_route53_zone.redis_local[0].zone_id : var.dns_hosted_zone_id
}

# Create Private Hosted Zone for redis.local
resource "aws_route53_zone" "redis_local" {
  count = local.create_route53_zone ? 1 : 0
  name  = var.ingress_domain

  # Make it a private hosted zone
  vpc {
    vpc_id     = module.region1.vpc_id
    vpc_region = var.region1
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_prefix}-redis-local-zone"
      Environment = var.environment
      Purpose     = "Active-Active DNS Resolution"
    }
  )

  lifecycle {
    ignore_changes = [vpc] # We'll add the second VPC separately
  }
}

# Associate the hosted zone with Region 2 VPC
resource "aws_route53_zone_association" "region2" {
  count      = local.create_route53_zone ? 1 : 0
  zone_id    = aws_route53_zone.redis_local[0].zone_id
  vpc_id     = module.region2.vpc_id
  vpc_region = var.region2
}

# Output the hosted zone ID for use in DNS module
output "route53_zone_id" {
  description = "Route53 Private Hosted Zone ID for redis.local"
  value       = local.effective_zone_id
}

output "route53_zone_name" {
  description = "Route53 Private Hosted Zone name"
  value       = local.create_route53_zone ? aws_route53_zone.redis_local[0].name : var.ingress_domain
}

