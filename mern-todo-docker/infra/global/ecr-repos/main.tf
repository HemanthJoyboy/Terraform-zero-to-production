terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "mern-todo-terraform-state-CHANGE-ME"   # matches bootstrap/main.tf's state_bucket_name
    key            = "global/ecr-repos/terraform.tfstate"
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

module "ecr" {
  source = "../../modules/ecr"

  tags = {
    ManagedBy = "terraform"
    Scope     = "global"
  }
}

output "repository_urls" {
  value = module.ecr.repository_urls
}
