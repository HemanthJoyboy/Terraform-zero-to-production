variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type        = string
  description = "From eks-cluster module's output"
}

variable "oidc_provider_url" {
  type        = string
  description = "From eks-cluster module's output (without the https:// prefix)"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace the ServiceAccount lives in, e.g. \"kube-system\""
}

variable "service_account_name" {
  type        = string
  description = "e.g. \"ebs-csi-controller-sa\" or \"aws-load-balancer-controller\""
}

variable "policy_arns" {
  type        = list(string)
  description = "IAM policy ARNs to attach - e.g. the AWS-managed AmazonEBSCSIDriverPolicy"
}

variable "tags" {
  type    = map(string)
  default = {}
}
