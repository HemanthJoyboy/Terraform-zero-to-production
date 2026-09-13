# The EKS control plane itself - the managed "top row" from the Kubernetes
# architecture diagram in README-k8s.md (API server, etcd, scheduler,
# controller-manager). AWS runs and patches these; this module just tells
# AWS to provision one, and wires up who's allowed to talk to it.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-sg-"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-cluster-sg" })
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    # Public endpoint access: fine for dev/test to keep kubectl simple.
    # Real prod clusters usually set this to false, or restrict
    # public_access_cidrs to the office/VPN CIDR only, and reach the
    # cluster over a VPN/bastion instead - see var.endpoint_public_access.
    endpoint_public_access = var.endpoint_public_access
  }

  # Required for the IRSA pattern (modules/irsa) to work at all -
  # this is what creates the OIDC "identity" that IAM roles can trust.
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = var.tags
}

# The OIDC provider is what lets Kubernetes ServiceAccounts assume real AWS
# IAM roles (IRSA - IAM Roles for Service Accounts) - see modules/irsa.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
