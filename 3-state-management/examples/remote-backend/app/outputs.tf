output "demo_bucket_name" {
  description = "Name of the demo bucket created by this project"
  value       = aws_s3_bucket.demo.id
}

output "state_location" {
  description = "Where this project's own state file lives"
  value       = "s3://my-company-terraform-state-CHANGE-ME/examples/remote-backend-app/terraform.tfstate"
}
