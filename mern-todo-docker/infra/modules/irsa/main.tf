# IRSA = IAM Roles for Service Accounts. This is THE mechanism that lets a
# pod (via its ServiceAccount) call real AWS APIs (create an ALB, attach an
# EBS volume) WITHOUT putting long-lived AWS access keys in a Kubernetes
# Secret. Both the EBS CSI driver and the ALB controller need one of these -
# this module is generic so both can reuse it, just with different policies
# and a different ServiceAccount name/namespace.
#
# How the trust actually works: the IAM role's trust policy below says
# "only the ServiceAccount named X in namespace Y, specifically on THIS
# cluster's OIDC provider, may assume this role" - scoped precisely, not
# "any pod in the cluster."

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.cluster_name}-${var.service_account_name}-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "attach" {
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
