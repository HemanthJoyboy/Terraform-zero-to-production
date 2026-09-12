# Override any default from variables.tf here.
# Example values shown below — edit as needed.

aws_region       = "ap-south-1"
project_name     = "terraform-demo"
instance_type    = "t2.micro"

# IMPORTANT: replace 0.0.0.0/0 with your own IP (e.g. "49.207.x.x/32") for real security.
# Find your IP: https://checkip.amazonaws.com
allowed_ssh_cidr = "0.0.0.0/0"
