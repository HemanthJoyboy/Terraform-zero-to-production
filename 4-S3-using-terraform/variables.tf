variable "aws_region" {
  description = "AWS region to create the bucket in"
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Globally-unique name for the S3 bucket (bucket names are unique across ALL of AWS, not just your account)"
  type        = string
}

variable "environment" {
  description = "Environment this bucket belongs to (used for tagging)"
  type        = string
  default     = "dev"
}

variable "enable_versioning" {
  description = "Whether to enable versioning on the bucket (keeps old versions of overwritten/deleted objects)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags to apply to the bucket"
  type        = map(string)
  default     = {}
}
