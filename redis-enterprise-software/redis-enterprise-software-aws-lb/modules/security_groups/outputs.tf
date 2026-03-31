output "redis_enterprise_sg_id" {
  description = "Security group ID for Redis Enterprise cluster nodes"
  value       = aws_security_group.redis_enterprise.id
}

output "redis_enterprise_sg_name" {
  description = "Security group name for Redis Enterprise cluster nodes"
  value       = aws_security_group.redis_enterprise.name
}
