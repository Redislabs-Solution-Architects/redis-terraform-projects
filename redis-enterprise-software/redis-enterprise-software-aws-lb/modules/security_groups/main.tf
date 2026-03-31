# =============================================================================
# REDIS ENTERPRISE SECURITY GROUPS
# =============================================================================
# Security groups for Redis Enterprise Software cluster
# =============================================================================

# Security group for Redis Enterprise cluster nodes
resource "aws_security_group" "redis_enterprise" {
  name_prefix = "${var.name_prefix}-redis-enterprise-sg"
  description = "Security group for Redis Enterprise cluster nodes"
  vpc_id      = var.vpc_id

  # SSH access
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allow_ssh_from
  }

  # Redis Enterprise UI (HTTPS)
  ingress {
    description = "Redis Enterprise UI"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = var.allow_ssh_from # Same as SSH for security
  }

  # Redis Enterprise REST API
  ingress {
    description = "Redis Enterprise REST API"
    from_port   = 9443
    to_port     = 9443
    protocol    = "tcp"
    cidr_blocks = var.allow_ssh_from # Same as SSH for security
  }

  # Redis Enterprise internal cluster communication
  ingress {
    description     = "Redis Enterprise cluster communication"
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise internal cluster communication (gossip protocol)
  ingress {
    description     = "Redis Enterprise gossip protocol"
    from_port       = 8002
    to_port         = 8002
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise internal cluster communication (discovery service)
  ingress {
    description     = "Redis Enterprise discovery service"
    from_port       = 8004
    to_port         = 8004
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise Sentinel service
  ingress {
    description     = "Redis Enterprise Sentinel"
    from_port       = 8006
    to_port         = 8006
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise cluster coordination service
  ingress {
    description     = "Redis Enterprise cluster coordination"
    from_port       = 3333
    to_port         = 3356
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise gossip communication port range
  ingress {
    description     = "Redis Enterprise gossip range"
    from_port       = 3342
    to_port         = 3346
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise CRDB coordination
  ingress {
    description     = "Redis Enterprise CRDB coordination"
    from_port       = 9081
    to_port         = 9081
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise metrics exporter and additional cluster communication
  ingress {
    description     = "Redis Enterprise metrics and cluster communication"
    from_port       = 8070
    to_port         = 8071
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis Enterprise internal proxy
  ingress {
    description     = "Redis Enterprise internal proxy"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # Redis database ports (default range)
  ingress {
    description = "Redis database ports"
    from_port   = 10000
    to_port     = 19999
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # ✅ Use variable instead
  }

  # Redis database ports for external access
  ingress {
    description = "Redis database external access"
    from_port   = 10000
    to_port     = 19999
    protocol    = "tcp"
    cidr_blocks = var.allow_ssh_from # Same as SSH for security
  }

  # Redis Enterprise shard replication ports (CRITICAL for replication links)
  ingress {
    description     = "Redis Enterprise shard replication communication"
    from_port       = 20000
    to_port         = 29999
    protocol        = "tcp"
    security_groups = []
    self            = true
  }

  # DNS queries for Redis Enterprise cluster DNS
  ingress {
    description = "DNS queries to Redis Enterprise DNS servers"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] # Allow DNS queries from anywhere
  }

  # DNS queries for Redis Enterprise cluster DNS (TCP)
  ingress {
    description = "DNS queries to Redis Enterprise DNS servers (TCP)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow DNS queries from anywhere
  }

  # All outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name    = "${var.name_prefix}-redis-enterprise-sg"
      Owner   = var.owner
      Project = var.project
      Type    = "Redis-Enterprise-SecurityGroup"
    },
    var.tags
  )
}
