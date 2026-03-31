#==============================================================================
# EKS NODE GROUP IAM ROLE
#==============================================================================

resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node_group.name
}

#==============================================================================
# NODE SECURITY GROUP
#==============================================================================

resource "aws_security_group" "node_group" {
  name        = "${var.cluster_name}-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-node-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )
}

# Allow all outbound traffic
resource "aws_security_group_rule" "node_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow all outbound traffic"
}

# Allow nodes to communicate with each other
resource "aws_security_group_rule" "node_ingress_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.node_group.id
  security_group_id        = aws_security_group.node_group.id
  description              = "Allow nodes to communicate with each other"
}

# Allow pods to communicate with the cluster API Server
resource "aws_security_group_rule" "node_ingress_cluster" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = var.cluster_security_group_id
  security_group_id        = aws_security_group.node_group.id
  description              = "Allow worker pods to receive communication from the cluster control plane"
}

# Allow cluster control plane to communicate with worker nodes
resource "aws_security_group_rule" "cluster_ingress_node_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node_group.id
  security_group_id        = var.cluster_security_group_id
  description              = "Allow pods to communicate with the cluster API Server"
}

# Allow Redis Enterprise ports (8001-9443, 10000-19999)
resource "aws_security_group_rule" "node_redis_enterprise_control" {
  type              = "ingress"
  from_port         = 8001
  to_port           = 9443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow Redis Enterprise control plane ports"
}

resource "aws_security_group_rule" "node_redis_enterprise_data" {
  type              = "ingress"
  from_port         = 10000
  to_port           = 19999
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow Redis Enterprise database ports"
}

# Allow DNS traffic (UDP port 53) - Required for Redis Enterprise
resource "aws_security_group_rule" "node_redis_enterprise_dns" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow DNS traffic for Redis Enterprise"
}

# Allow DNS traffic (TCP port 53) - Required for Redis Enterprise
resource "aws_security_group_rule" "node_redis_enterprise_dns_tcp" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow DNS traffic (TCP) for Redis Enterprise"
}

# Allow mDNS traffic (UDP port 5353) - Required for Redis Enterprise
resource "aws_security_group_rule" "node_redis_enterprise_mdns" {
  type              = "ingress"
  from_port         = 5353
  to_port           = 5353
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow mDNS traffic for Redis Enterprise"
}

# =============================================================================
# ACTIVE-ACTIVE (CRDB) REPLICATION PORTS
# =============================================================================
# These ports are CRITICAL for Redis Enterprise Active-Active database
# replication and coordination between clusters in different regions

# Allow Redis Enterprise shard replication ports (CRITICAL for Active-Active data sync)
resource "aws_security_group_rule" "node_redis_enterprise_replication" {
  type              = "ingress"
  from_port         = 20000
  to_port           = 29999
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow Redis Enterprise shard replication (Active-Active CRDB)"
}

# Allow Redis Enterprise cluster coordination (CRITICAL for cluster communication)
resource "aws_security_group_rule" "node_redis_enterprise_coordination" {
  type              = "ingress"
  from_port         = 3333
  to_port           = 3356
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow Redis Enterprise cluster coordination"
}

# Allow Redis Enterprise CRDB coordination (CRITICAL for Active-Active)
resource "aws_security_group_rule" "node_redis_enterprise_crdb" {
  type              = "ingress"
  from_port         = 9081
  to_port           = 9081
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group.id
  description       = "Allow Redis Enterprise CRDB coordination (Active-Active)"
}

#==============================================================================
# LAUNCH TEMPLATE
#==============================================================================

resource "aws_launch_template" "node_group" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Launch template for ${var.cluster_name} EKS nodes"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-node"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-node-root"
      }
    )
  }

  tag_specifications {
    resource_type = "network-interface"

    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-node-eni"
      }
    )
  }

  tags = var.tags
}

#==============================================================================
# EKS NODE GROUP
#==============================================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  instance_types = var.instance_types

  launch_template {
    id      = aws_launch_template.node_group.id
    version = "$Latest"
  }

  labels = {
    role = "redis-enterprise"
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEBSCSIDriverPolicy,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
