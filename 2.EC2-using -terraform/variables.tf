variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix used for tagging all resources"
  type        = string
  default     = "terraform-demo"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the instance. Restrict this to your own IP for security, e.g. \"1.2.3.4/32\"."
  type        = string
  default     = "0.0.0.0/0"
}
