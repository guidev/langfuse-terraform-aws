data "aws_eks_cluster_auth" "langfuse" {
  name = aws_eks_cluster.langfuse.name
}

resource "aws_eks_cluster" "langfuse" {
  name     = var.name
  role_arn = aws_iam_role.eks.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = local.private_subnets
    # Private-only API endpoint: reached over the VPN + VPC peering, never the
    # public internet (satisfies CIS "EKS public access limited" / "private
    # endpoint enabled"). Terraform's kubernetes/helm providers and kubectl must
    # run over the VPN.
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [aws_security_group.eks.id]
  }

  # Envelope-encrypt Kubernetes Secrets with a customer-managed KMS key. Adding
  # this to an existing cluster is an in-place update; it cannot be removed.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name = local.tag_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
    aws_iam_role_policy.eks_kms,
    aws_cloudwatch_log_group.eks
  ]
}

# Enable IRSA
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer

  tags = {
    Name = local.tag_name
  }
}

# Get EKS OIDC certificate
data "tls_certificate" "eks" {
  url = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer
}

# Fargate Profile Role
resource "aws_iam_role" "fargate" {
  name = "${var.name}-fargate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.tag_name} Fargate"
  }
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate.name
}

# Fargate Profiles for all configured namespaces
resource "aws_eks_fargate_profile" "namespaces" {
  for_each = toset(var.fargate_profile_namespaces)

  cluster_name           = aws_eks_cluster.langfuse.name
  fargate_profile_name   = "${var.name}-${each.value}"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = local.private_subnets

  selector {
    namespace = each.value
  }

  tags = {
    Name = local.tag_name
  }
}

# EKS installs CoreDNS configured for EC2 infrastructure, so on a Fargate-only
# cluster its pods stay Pending on the eks.amazonaws.com/compute-type=fargate
# taint. Nothing in the cluster resolves DNS until that is fixed: the AWS Load
# Balancer Controller cannot reach STS, and the Langfuse pods cannot resolve
# the database hostnames.
#
# Managing CoreDNS as an add-on lets EKS render the deployment for Fargate
# itself, which is more durable than patching the annotation of an
# EKS-managed object after the fact. The kube-system Fargate profile selects
# on the namespace alone, so it already matches the CoreDNS pods.
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.langfuse.name
  addon_name   = "coredns"

  configuration_values = jsonencode({
    computeType = "Fargate"
  })

  # CoreDNS is pre-installed by EKS, so the add-on adopts an object Terraform
  # does not own.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The add-on only reaches ACTIVE once its pods schedule, which needs the
  # profile to exist first.
  depends_on = [
    aws_eks_fargate_profile.namespaces,
  ]

  tags = {
    Name = "${local.tag_name} CoreDNS"
  }
}

resource "aws_security_group" "eks" {
  name        = "${var.name}-eks"
  description = "Security group for Langfuse EKS cluster"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${local.tag_name} EKS"
  }
}

resource "aws_security_group_rule" "eks_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks.id
}

resource "aws_security_group_rule" "eks_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr_block]
  security_group_id = aws_security_group.eks.id
}

# Reach the private API server (443) from outside the VPC — e.g. Client VPN
# admins running kubectl or the Terraform kubernetes/helm providers over a VPN
# + VPC peering. No-op when eks_api_inbound_cidrs is empty (the default).
resource "aws_security_group_rule" "eks_api_inbound" {
  count             = length(var.eks_api_inbound_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.eks_api_inbound_cidrs
  security_group_id = aws_security_group.eks.id
  description       = "API server access for external (VPN) operators"
}

resource "aws_iam_role" "eks" {
  name = "${var.name}-eks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.tag_name} EKS"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 400 # control-plane audit log: access & security tier (docs/logging-and-retention.md)
}

resource "aws_kms_key" "eks" {
  description             = "${local.tag_name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name = "${local.tag_name} EKS"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_iam_role_policy" "eks_kms" {
  name = "kms-secrets-encryption"
  role = aws_iam_role.eks.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
        Resource = aws_kms_key.eks.arn
      }
    ]
  })
}
