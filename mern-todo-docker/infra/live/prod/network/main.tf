terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "mern-todo-terraform-state-CHANGE-ME"
    key            = "prod/network/terraform.tfstate"   # unique per environment+component - see README-terraform.md Section 2
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
  # In a real multi-account setup, this is where assume_role would go:
  # assume_role { role_arn = "arn:aws:iam::<DEV_ACCOUNT_ID>:role/TerraformExecutionRole" }
}

module "network" {
  source = "../../../modules/vpc"

  name_prefix        = "mern-todo-prod"
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

output "vpc_id" {
  value = module.network.vpc_id
}
output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}
output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}
