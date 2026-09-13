# Installs the controller that watches the app's k8s/09-ingress.yaml and
# turns it into a real AWS ALB (see README-k8s.md Section 4, Step 4, and
# Section 5's "Do you need Ingress" walkthrough). This module both grants
# the AWS permissions it needs (via IRSA) AND installs the controller
# itself into the cluster via Helm - so `terraform apply` on this one
# module is the full equivalent of that section's eksctl + helm commands.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

# The AWS-managed policy document for this controller isn't a single ARN
# like the EBS driver's - AWS publishes it as a JSON policy document you
# create yourself, once per account. In a real repo this JSON lives in a
# file (iam-policy.json) fetched from the aws-load-balancer-controller
# GitHub releases page - referenced here, kept out of this file for length.
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam-policy.json")
}

module "irsa" {
  source = "../irsa"

  cluster_name         = var.cluster_name
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider_url    = var.oidc_provider_url
  namespace            = "kube-system"
  service_account_name = "aws-load-balancer-controller"
  policy_arns          = [aws_iam_policy.alb_controller.arn]
  tags                 = var.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # The ServiceAccount itself (with the IRSA role annotation) is created
  # separately, via the kubernetes provider, since serviceAccount.create=false
  # above tells the Helm chart NOT to create its own.
  depends_on = [kubernetes_service_account.alb_controller]
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa.role_arn
    }
  }
}
