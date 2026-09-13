terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "mern-todo-terraform-state-CHANGE-ME"
    key            = "test/k8s-addons/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "mern-todo-terraform-state-CHANGE-ME"
    key    = "test/eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

# Both the kubernetes and helm providers need to authenticate to the
# cluster - this is HOW: the token comes from AWS IAM (via
# aws_eks_cluster_auth), not a separate kubeconfig file.
provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    token                  = data.aws_eks_cluster_auth.this.token
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
  }
}

module "ebs_csi" {
  source = "../../../modules/ebs-csi"

  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url

  tags = { Environment = "test", ManagedBy = "terraform" }
}

module "alb_controller" {
  source = "../../../modules/alb-controller"

  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url

  tags = { Environment = "test", ManagedBy = "terraform" }
}
