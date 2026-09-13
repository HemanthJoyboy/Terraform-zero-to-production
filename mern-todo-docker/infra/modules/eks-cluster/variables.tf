variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type        = string
  description = "e.g. \"1.29\". Pin explicitly - never leave this to \"latest\", or a routine apply could trigger an unplanned control-plane upgrade."
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "EKS control plane + worker nodes live in private subnets - the ALB (public-facing) lives in the public ones instead"
}

variable "endpoint_public_access" {
  type        = bool
  description = "true = kubectl works from anywhere with valid AWS creds (simpler, fine for dev/test). false = must reach the API server via VPN/bastion (more common for prod)."
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
