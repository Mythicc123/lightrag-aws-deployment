output "elastic_ip" {
  description = "Elastic IP address of the LightRAG EC2 instance"
  value       = aws_eip.lightrag.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.lightrag.id
}

output "s3_bucket_name" {
  description = "S3 bucket name for rag_storage/ persistence"
  value       = aws_s3_bucket.graph_storage.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/ec2-static-site-key.pem ubuntu@${aws_eip.lightrag.public_ip}"
}

output "endpoint_url" {
  description = "LightRAG API/WebUI endpoint URL"
  value       = "http://${aws_eip.lightrag.public_ip}:9621"
}

output "iam_instance_profile" {
  description = "IAM instance profile name attached to the EC2 instance"
  value       = aws_iam_instance_profile.lightrag.name
}
