variable "aws_region" {
  description = "AWS region for this project's resources"
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Name of a simple demo S3 bucket created by this project (just to prove the remote backend works end-to-end)"
  type        = string
  default     = "remote-backend-demo-bucket-CHANGE-ME"
}
