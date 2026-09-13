# Without this, the PersistentVolumeClaim in the app's k8s/04-postgres.yaml
# StatefulSet would sit forever in Pending - nothing would ever turn it
# into a real EBS volume. This module is the Terraform version of the
# `eksctl create iamserviceaccount` + `eksctl create addon` commands from
# README-k8s.md Section 4, Step 3.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

module "irsa" {
  source = "../irsa"

  cluster_name          = var.cluster_name
  oidc_provider_arn     = var.oidc_provider_arn
  oidc_provider_url     = var.oidc_provider_url
  namespace             = "kube-system"
  service_account_name  = "ebs-csi-controller-sa"
  policy_arns           = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  tags                  = var.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa.role_arn
  resolve_conflicts_on_update = "OVERWRITE"
  tags                     = var.tags
}
