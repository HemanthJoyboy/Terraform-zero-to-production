output "bucket_id" {
  description = "The name of the bucket"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The ARN of the bucket"
  value       = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  description = "The bucket's regional domain name (useful for referencing in other resources, e.g. CloudFront)"
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}
