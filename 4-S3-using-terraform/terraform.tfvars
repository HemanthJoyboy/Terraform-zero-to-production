# Override defaults here. bucket_name is required (no default) since it
# must be globally unique - pick something specific to you/your project.

aws_region        = "ap-south-1"
bucket_name       = "my-unique-demo-bucket-12345"   # <-- CHANGE THIS
environment       = "dev"
enable_versioning = true

tags = {
  Owner   = "your-name"
  Project = "terraform-learning"
}
