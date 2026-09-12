# A tiny, harmless demo resource — the point of this project isn't
# what it creates, but proving that its STATE is stored remotely
# in S3 with DynamoDB locking (see backend.tf).

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket_name

  tags = {
    Name    = "Remote Backend Demo"
    Purpose = "prove-remote-state-works"
  }
}
