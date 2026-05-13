# =============================================================================
# variables.tf — AgriCam Infrastructure AWS
# Adapté pour CI/CD : ajout de ec2_public_key
# =============================================================================

variable "aws_region" {
  description = "Region AWS ou deployer les ressources"
  type        = string
  default     = "af-south-1"
}

variable "environnement" {
  description = "Nom de l'environnement (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environnement)
    error_message = "La valeur doit être 'dev', 'staging' ou 'prod'."
  }
}

variable "type_instance" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t2.micro"

  validation {
    condition     = contains(["t2.micro", "t2.small", "t2.medium", "t3.micro", "t3.small"], var.type_instance)
    error_message = "Type d'instance non autorisé. Choisir parmi : t2.micro, t2.small, t2.medium, t3.micro, t3.small."
  }
}

variable "ami_id" {
  description = "ID de l'image AMI Ubuntu 22.04 pour af-south-1"
  type        = string

  validation {
    condition     = can(regex("^ami-[a-z0-9]+$", var.ami_id))
    error_message = "L'AMI ID doit commencer par 'ami-' suivi de caractères alphanumériques."
  }
}

variable "ip_admin" {
  description = "IP publique de l'administrateur autorise au SSH (format: x.x.x.x/32)"
  type        = string
  sensitive   = true # Masquée dans les logs Terraform

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.ip_admin))
    error_message = "L'IP admin doit être au format x.x.x.x/32 (ex: 41.202.207.100/32)."
  }
}

# NOUVEAU — Clé publique SSH injectée via GitHub Secret
# Remplace file("~/.ssh/agricam_key.pub") qui ne fonctionne pas en CI/CD
# Valeur attendue : le contenu de votre fichier .pub (ssh-rsa AAAA...)
variable "ec2_public_key" {
  description = "Contenu de la cle publique SSH pour acceder aux instances EC2"
  type        = string
  sensitive   = true # Masquée dans les logs Terraform

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) ", var.ec2_public_key))
    error_message = "La clé publique doit commencer par 'ssh-rsa', 'ssh-ed25519' ou 'ecdsa-sha2-nistp256'."
  }
}
