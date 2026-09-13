# Run this ONCE, manually, before anything else in this repo. Everything
# under live/ and global/ needs this bucket+table to already exist before
# their own `terraform init` can even run - so this can't itself use a
# remote backend (chicken-and-egg problem). Its state is fine sitting
# locally, or you can migrate it to S3 later once the bucket exists.
#
# Usage:
#   cd infra/bootstrap
#   terraform init
#   terraform apply

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Must be globally unique across ALL of AWS, not just your account"
  default     = "mern-todo-terraform-state-CHANGE-ME"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # Prevents `terraform destroy` (run against the WRONG folder by accident)
  # from being able to delete the bucket every other environment's state
  # lives in. This is a real incident that happens without this.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"   # every state change keeps a prior version - lets you recover from a bad apply that corrupted state
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table used purely for STATE LOCKING (not for storing state itself -
# that's the S3 bucket above). Terraform writes a lock row here for the
# duration of any plan/apply, so a second `terraform apply` against the
# same state key blocks instead of racing and corrupting state.
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.terraform_locks.name
}
