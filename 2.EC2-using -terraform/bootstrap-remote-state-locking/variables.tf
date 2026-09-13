variable "aws_region" {
  description = "AWS region to create the backend resources in"
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for storing your Terraform state files"
  type        = string
  default     = "my-ec2-project-terraform-state-CHANGE-ME"
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  type        = string
  default     = "terraform-locks"
}
