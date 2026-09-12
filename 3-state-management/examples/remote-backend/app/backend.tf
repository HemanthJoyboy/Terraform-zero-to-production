# This project's state is stored remotely in the bucket/table
# created by ../bootstrap. Update these values to match your
# bootstrap outputs if you changed the defaults.

terraform {
  backend "s3" {
    bucket         = "my-company-terraform-state-CHANGE-ME"
    key            = "examples/remote-backend-app/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
