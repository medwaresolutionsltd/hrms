output "elastic_ip" {
  description = "Create a DNS A record for your domain pointing at this address."
  value       = aws_eip.app.public_ip
}

output "dns_record" {
  description = "The DNS record to create at your domain provider."
  value       = "A  ${var.domain_name}  ->  ${aws_eip.app.public_ip}"
}

output "site_url" {
  value = "https://${var.domain_name}"
}

output "instance_id" {
  value = aws_instance.app.id
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "connect_command" {
  description = "Open a shell on the server (no SSH needed). Requires the AWS CLI and the Session Manager plugin."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.app.id}"
}

output "watch_bootstrap_command" {
  description = "Run inside the session to follow the first-boot install (the first build takes 20-40 minutes)."
  value       = "sudo tail -f /var/log/medware-bootstrap.log"
}

output "admin_password_command" {
  description = "Prints the generated Administrator password. Change it after your first login."
  value       = "aws ssm get-parameter --region ${var.region} --name ${local.ssm_prefix}/admin_password --with-decryption --query Parameter.Value --output text"
}
