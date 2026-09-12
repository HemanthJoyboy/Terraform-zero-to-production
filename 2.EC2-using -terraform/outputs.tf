output "instance_id" {
  description = "ID of the newly created EC2 instance"
  value       = aws_instance.this.id
}

output "instance_public_ip" {
  description = "Public IP address of the newly created EC2 instance"
  value       = aws_instance.this.public_ip
}

output "ssh_command" {
  description = "Ready-to-use SSH command to connect to the new instance"
  value       = "ssh -i new-ec2-key.pem ec2-user@${aws_instance.this.public_ip}"
}
