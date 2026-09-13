# Add this file to your EXISTING terraform-ec2-demo project
# (the folder that already contains providers.tf, main.tf, etc.
#  for the EC2 instance you already created).
#
# Update bucket / dynamodb_table below to match the outputs from
# `terraform apply` inside backend-bootstrap/.

terraform {
  backend "s3" {
    bucket         = "my-ec2-project-terraform-state-CHANGE-ME"
    key            = "2.EC2-using -terraform/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
