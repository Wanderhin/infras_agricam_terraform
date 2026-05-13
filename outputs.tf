# =============================================================================
# outputs.tf — AgriCam Infrastructure AWS
# Valeurs exposées après terraform apply
# =============================================================================

output "ip_publique_serveur" {
  description = "Adresse IP publique du serveur AgriCam"
  value       = aws_instance.agricam_serveur.public_ip
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
  value       = "http://${aws_instance.agricam_serveur.public_ip}"
}

output "commande_ssh" {
  description = "Commande SSH pour se connecter au serveur (remplacer le chemin de la clé)"
  value       = "ssh -i ~/.ssh/agricam_key ubuntu@${aws_instance.agricam_serveur.public_ip}"
  sensitive   = false
}
