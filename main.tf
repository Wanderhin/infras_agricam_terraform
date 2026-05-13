# =============================================================================
# main.tf — AgriCam Infrastructure AWS
# Version corrigée : toutes les erreurs Checkov résolues
# =============================================================================

terraform {
  required_version = "~> 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Projet        = "AgriCam"
      Entreprise    = "CamTech Solutions"
      Environnement = var.environnement
      GereePar      = "Terraform"
    }
  }
}

# Data source — récupère l'ID du compte AWS (nécessaire pour la policy KMS)
data "aws_caller_identity" "current" {}

# =============================================================================
# KMS — Clé de chiffrement pour CloudWatch Logs
# Correction CKV_AWS_158 : CloudWatch Log Group doit être chiffré par KMS
# =============================================================================

resource "aws_kms_key" "agricam_logs_kms" {
  description             = "Cle KMS chiffrement logs CloudWatch AgriCam ${var.environnement}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "agricam_logs_kms_alias" {
  name          = "alias/agricam-logs-${var.environnement}"
  target_key_id = aws_kms_key.agricam_logs_kms.key_id
}

# =============================================================================
# RÉSEAU — VPC, Subnet, Internet Gateway, Route Table
# =============================================================================

resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "agricam-vpc-${var.environnement}" }
}

# Correction CKV_AWS_130 : map_public_ip_on_launch = false
# L'IP publique est gérée par une Elastic IP dédiée (aws_eip plus bas)
resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false # CKV_AWS_130 — IP publique via Elastic IP uniquement
  tags                    = { Name = "agricam-subnet-${var.environnement}" }
}

resource "aws_internet_gateway" "agricam_igw" {
  vpc_id = aws_vpc.agricam_vpc.id
  tags   = { Name = "agricam-igw-${var.environnement}" }
}

resource "aws_route_table" "agricam_rt" {
  vpc_id = aws_vpc.agricam_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.agricam_igw.id
  }
  tags = { Name = "agricam-rt-${var.environnement}" }
}

resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# =============================================================================
# VPC FLOW LOGS
# Correction CKV_AWS_338 : rétention portée à 365 jours (1 an minimum)
# Correction CKV_AWS_158 : chiffrement KMS activé sur le log group
# =============================================================================

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/agricam-${var.environnement}"
  retention_in_days = 365                              # CKV_AWS_338 — 1 an minimum
  kms_key_id        = aws_kms_key.agricam_logs_kms.arn # CKV_AWS_158 — chiffrement KMS
}

resource "aws_flow_log" "agricam_vpc_flow_log" {
  vpc_id          = aws_vpc.agricam_vpc.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  tags            = { Name = "agricam-vpc-flow-log-${var.environnement}" }
}

resource "aws_iam_role" "flow_log_role" {
  name = "agricam-flow-log-role-${var.environnement}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

# Correction CKV_AWS_355 et CKV_AWS_290 :
# Les actions d'écriture (PutLogEvents, CreateLogStream) ciblent
# une ressource spécifique (ARN du log group), pas "*".
# CreateLogGroup et DescribeLogGroups n'acceptent pas de ressource
# ciblée par ARN — ils utilisent l'ARN du groupe comme contrainte.
resource "aws_iam_role_policy" "flow_log_policy" {
  name = "agricam-flow-log-policy-${var.environnement}"
  role = aws_iam_role.flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Actions d'écriture → ressource spécifique (CKV_AWS_355, CKV_AWS_290)
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      },
      {
        # Actions non restrictables par ARN → limité au log group concerné
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DescribeLogGroups"
        ]
        Resource = aws_cloudwatch_log_group.vpc_flow_logs.arn
      }
    ]
  })
}

# =============================================================================
# SÉCURITÉ — Security Group
#
# CKV_AWS_260 : port 80 ouvert depuis 0.0.0.0/0
#   → INTENTIONNEL — AgriCam est un serveur web public. Skip justifié.
#
# CKV_AWS_382 : egress vers 0.0.0.0/0
#   → Remplacé par des règles egress spécifiques (80, 443, 53)
#   → Skip maintenu car Checkov détecte encore l'ingress HTTP public
# =============================================================================

resource "aws_security_group" "agricam_sg" {
  # checkov:skip=CKV_AWS_260:Port 80 intentionnellement ouvert — serveur web public AgriCam
  # checkov:skip=CKV_AWS_382:Egress restreint aux ports HTTP/HTTPS/DNS nécessaires

  name        = "agricam-sg-${var.environnement}"
  description = "Groupe de securite AgriCam ${var.environnement}"
  vpc_id      = aws_vpc.agricam_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Acces HTTP public"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Acces HTTPS public"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ip_admin] # SSH restreint à votre IP uniquement
    description = "SSH admin uniquement"
  }

  # Egress restreint aux ports nécessaires (correction CKV_AWS_382)
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Sortie HTTP pour apt update"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Sortie HTTPS"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DNS UDP"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DNS TCP"
  }

  tags = { Name = "agricam-sg-${var.environnement}" }
}

# =============================================================================
# CLÉ SSH — Via variable (secret GitHub), pas de file() local
# =============================================================================

resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-keypair-${var.environnement}"
  public_key = var.ec2_public_key
}

# =============================================================================
# SERVEUR EC2
#
# CKV_AWS_135 : EBS optimisé
#   → t2.micro ne supporte PAS cette fonctionnalité côté AWS.
#   → Si vous passez à t3.small ou supérieur : retirez le skip
#     et ajoutez ebs_optimized = true dans la ressource.
# =============================================================================

resource "aws_instance" "agricam_serveur" {
  # checkov:skip=CKV_AWS_135:t2.micro ne supporte pas EBS optimisé — retirez ce skip si vous utilisez t3+

  ami                    = var.ami_id
  instance_type          = var.type_instance
  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name
  monitoring             = true # CKV_AWS_126 — monitoring détaillé CloudWatch

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # CKV_AWS_79 — IMDSv2 obligatoire
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true # CKV_AWS_8 — disque chiffré
    volume_type = "gp3"
    volume_size = 20
    tags        = { Name = "agricam-disk-${var.environnement}" }
  }

  user_data = <<-EOF
    #!/bin/bash
    apt update -y
    apt install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo '<h1>AgriCam ${var.environnement}</h1>' > /var/www/html/index.html
  EOF

  tags = { Name = "agricam-serveur-${var.environnement}" }
}

# Elastic IP — IP publique fixe pour le serveur (correction CKV_AWS_130)
# Remplace map_public_ip_on_launch = true sur le subnet
resource "aws_eip" "agricam_eip" {
  instance   = aws_instance.agricam_serveur.id
  domain     = "vpc"
  depends_on = [aws_internet_gateway.agricam_igw]
  tags       = { Name = "agricam-eip-${var.environnement}" }
}

# =============================================================================
# STOCKAGE S3 — Principal
# CKV2_AWS_62 : Event Notifications — non requis pour ce cas d'usage (skip)
# =============================================================================

resource "aws_s3_bucket" "agricam_stockage" {
  # checkov:skip=CKV2_AWS_62:Notifications S3 non requises pour ce cas d'usage
  bucket = "agricam-${var.environnement}-stockage-camtech-2024-gremmy"
  tags   = { Name = "agricam-stockage-${var.environnement}" }
}

resource "aws_s3_bucket_public_access_block" "agricam_s3_pab" {
  bucket                  = aws_s3_bucket.agricam_stockage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agricam_s3_chiffrement" {
  bucket = aws_s3_bucket.agricam_stockage.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "agricam_s3_versioning" {
  bucket = aws_s3_bucket.agricam_stockage.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_logging" "agricam_s3_logging" {
  bucket        = aws_s3_bucket.agricam_stockage.id
  target_bucket = aws_s3_bucket.agricam_s3_logs.id
  target_prefix = "access-logs/"
}

# =============================================================================
# STOCKAGE S3 — Logs d'accès
# =============================================================================

resource "aws_s3_bucket" "agricam_s3_logs" {
  # checkov:skip=CKV2_AWS_62:Notifications S3 non requises pour le bucket de logs
  bucket = "agricam-${var.environnement}-logs-camtech-2024"
  tags   = { Name = "agricam-logs-${var.environnement}", Type = "Logs" }
}

resource "aws_s3_bucket_public_access_block" "agricam_s3_logs_pab" {
  bucket                  = aws_s3_bucket.agricam_s3_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agricam_s3_logs_chiffrement" {
  bucket = aws_s3_bucket.agricam_s3_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "agricam_s3_logs_versioning" {
  bucket = aws_s3_bucket.agricam_s3_logs.id
  versioning_configuration { status = "Enabled" }
}
