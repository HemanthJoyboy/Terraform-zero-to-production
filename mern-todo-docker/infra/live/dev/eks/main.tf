terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "mern-todo-terraform-state-CHANGE-ME"
    key            = "dev/eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# This is HOW separate state files talk to each other: not by magic, but by
# explicitly reading another component's OUTPUTS out of its state file. The
# eks component doesn't "know about" the network component's resources -
# it only knows the specific output values network/main.tf chose to expose.
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "mern-todo-terraform-state-CHANGE-ME"
    key    = "dev/network/terraform.tfstate"
    region = "us-east-1"
  }
}

module "eks_cluster" {
  source = "../../../modules/eks-cluster"

  cluster_name        = "mern-todo-dev"
  kubernetes_version  = var.kubernetes_version
  vpc_id              = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids  = data.terraform_remote_state.network.outputs.private_subnet_ids
  endpoint_public_access = true   # dev: simple kubectl access is worth more than the extra hardening

  tags = { Environment = "dev", ManagedBy = "terraform" }
}

module "node_group" {
  source = "../../../modules/node-group"

  cluster_name       = module.eks_cluster.cluster_name
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  instance_types = var.instance_types
  capacity_type  = var.capacity_type
  desired_size   = var.desired_size
  min_size       = var.min_size
  max_size       = var.max_size

  tags = { Environment = "dev", ManagedBy = "terraform" }
}

output "cluster_name" {
  value = module.eks_cluster.cluster_name
}
output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}
output "cluster_certificate_authority_data" {
  value = module.eks_cluster.cluster_certificate_authority_data
}
output "oidc_provider_arn" {
  value = module.eks_cluster.oidc_provider_arn
}
output "oidc_provider_url" {
  value = module.eks_cluster.oidc_provider_url
}
