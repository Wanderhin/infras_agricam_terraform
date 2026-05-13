# =============================================================================
# outputs.tf — AgriCam
# Mis à jour : ip_publique via Elastic IP (plus map_public_ip_on_launch)
# =============================================================================

output "ip_publique_serveur" {
  description = "Adresse IP publique (Elastic IP) du serveur AgriCam"
  value       = aws_eip.agricam_eip.public_ip
}

output "nom_bucket_s3" {
  description = "Nom du bucket S3 de stockage principal"
  value       = aws_s3_bucket.agricam_stockage.bucket
}

output "nom_bucket_logs" {
  description = "Nom du bucket S3 des logs d'accès"
  value       = aws_s3_bucket.agricam_s3_logs.bucket
}

output "id_vpc" {
  description = "Identifiant du VPC créé"
  value       = aws_vpc.agricam_vpc.id
}

output "id_subnet" {
  description = "Identifiant du Subnet public"
  value       = aws_subnet.agricam_subnet.id
}

output "id_security_group" {
  description = "Identifiant du Security Group"
  value       = aws_security_group.agricam_sg.id
}

output "url_application" {
  description = "URL de l'application AgriCam (HTTP)"
  value       = "http://${aws_eip.agricam_eip.public_ip}"
}

output "commande_ssh" {
  description = "Commande SSH pour se connecter au serveur"
  value       = "ssh -i ~/.ssh/agricam_key ubuntu@${aws_eip.agricam_eip.public_ip}"
}

output "kms_key_id" {
  description = "ID de la clé KMS pour CloudWatch Logs"
  value       = aws_kms_key.agricam_logs_kms.key_id
}
