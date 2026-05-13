# =============================================================================
# main.tf — AgriCam Infrastructure AWS
# Adapté pour CI/CD GitHub Actions
# Corrections : backend distant, clé SSH via variable, sécurité renforcée
# =============================================================================

terraform {
  required_version = "~> 1.7.0"   # Version épinglée — importante pour la reproductibilité

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend distant S3 — obligatoire pour CI/CD
  # Les valeurs sont injectées par GitHub Actions via -backend-config
  # NE PAS mettre les valeurs ici en dur (elles viennent des secrets GitHub)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # Bonne pratique : tagger automatiquement toutes les ressources créées
  default_tags {
    tags = {
      Projet        = "AgriCam"
      Entreprise    = "CamTech Solutions"
      Environnement = var.environnement
      GereePar      = "Terraform"
      Depot         = "github.com/votre-org/agricam-infra"
    }
  }
}

# =============================================================================
# RÉSEAU — VPC, Subnet, Internet Gateway, Route Table
# =============================================================================

resource "aws_vpc" "agricam_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "agricam-vpc-${var.environnement}"
  }
}

resource "aws_subnet" "agricam_subnet" {
  vpc_id                  = aws_vpc.agricam_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "agricam-subnet-${var.environnement}"
  }
}

resource "aws_internet_gateway" "agricam_igw" {
  vpc_id = aws_vpc.agricam_vpc.id

  tags = {
    Name = "agricam-igw-${var.environnement}"
  }
}

resource "aws_route_table" "agricam_rt" {
  vpc_id = aws_vpc.agricam_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.agricam_igw.id
  }

  tags = {
    Name = "agricam-rt-${var.environnement}"
  }
}

resource "aws_route_table_association" "agricam_rta" {
  subnet_id      = aws_subnet.agricam_subnet.id
  route_table_id = aws_route_table.agricam_rt.id
}

# VPC Flow Logs — journalise tout le trafic réseau (requis Checkov CKV2_AWS_11)
resource "aws_flow_log" "agricam_vpc_flow_log" {
  vpc_id          = aws_vpc.agricam_vpc.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = {
    Name = "agricam-vpc-flow-log-${var.environnement}"
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/agricam-${var.environnement}"
  retention_in_days = 90   # Conservation 90 jours minimum (conformité)
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

resource "aws_iam_role_policy" "flow_log_policy" {
  name = "agricam-flow-log-policy-${var.environnement}"
  role = aws_iam_role.flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# =============================================================================
# SÉCURITÉ — Security Group
# SSH restreint à votre IP uniquement (var.ip_admin)
# =============================================================================

resource "aws_security_group" "agricam_sg" {
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
    cidr_blocks = [var.ip_admin]    # UNIQUEMENT votre IP — jamais 0.0.0.0/0
    description = "SSH admin uniquement"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Sortie internet"
  }

  tags = {
    Name = "agricam-sg-${var.environnement}"
  }
}

# =============================================================================
# CLÉ SSH — Injectée via variable (GitHub Secret) au lieu de file()
# CORRECTION CI/CD : file("~/.ssh/agricam_key.pub") ne fonctionne pas
# dans GitHub Actions car ce chemin local n'existe pas sur le runner.
# La clé publique est stockée dans un secret GitHub et passée en variable.
# =============================================================================

resource "aws_key_pair" "agricam_keypair" {
  key_name   = "agricam-keypair-${var.environnement}"
  public_key = var.ec2_public_key   # Vient du secret GitHub EC2_PUBLIC_KEY
}

# =============================================================================
# SERVEUR EC2 — Avec sécurité renforcée
# Corrections pour passer Checkov :
#   - Chiffrement EBS (disque) activé          (CKV_AWS_8)
#   - IMDSv2 obligatoire                       (CKV_AWS_79)
#   - Monitoring détaillé activé               (CKV_AWS_126)
# =============================================================================

resource "aws_instance" "agricam_serveur" {
  ami                    = var.ami_id
  instance_type          = var.type_instance
  subnet_id              = aws_subnet.agricam_subnet.id
  vpc_security_group_ids = [aws_security_group.agricam_sg.id]
  key_name               = aws_key_pair.agricam_keypair.key_name
  monitoring             = true   # Monitoring CloudWatch détaillé (CKV_AWS_126)

  # IMDSv2 obligatoire — empêche les attaques SSRF sur les métadonnées (CKV_AWS_79)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # "required" = IMDSv2 uniquement
    http_put_response_hop_limit = 1
  }

  # Chiffrement du disque racine (CKV_AWS_8)
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
    tags = {
      Name = "agricam-disk-${var.environnement}"
    }
  }

  user_data = <<-EOF
    #!/bin/bash
    apt update -y
    apt install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo '<h1>AgriCam ${var.environnement}</h1>' > /var/www/html/index.html
  EOF

  tags = {
    Name = "agricam-serveur-${var.environnement}"
  }
}

# =============================================================================
# STOCKAGE S3 — Avec chiffrement et versionnage (sécurité chapitre 4)
# Corrections Checkov :
#   - Chiffrement AES256 activé    (CKV_AWS_19)
#   - Versionnage activé           (CKV_AWS_21)
#   - Logging d'accès activé       (CKV_AWS_18)
#   - Blocage accès public         (déjà présent dans votre code original)
# =============================================================================

resource "aws_s3_bucket" "agricam_stockage" {
  bucket = "agricam-${var.environnement}-stockage-camtech-2024-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "agricam-stockage-${var.environnement}"
  }
}

# Blocage total de l'accès public (déjà dans votre code — conservé)
resource "aws_s3_bucket_public_access_block" "agricam_s3_pab" {
  bucket                  = aws_s3_bucket.agricam_stockage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Chiffrement AES256 côté serveur (CKV_AWS_19)
resource "aws_s3_bucket_server_side_encryption_configuration" "agricam_s3_chiffrement" {
  bucket = aws_s3_bucket.agricam_stockage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versionnage — protège contre les suppressions accidentelles (CKV_AWS_21)
resource "aws_s3_bucket_versioning" "agricam_s3_versioning" {
  bucket = aws_s3_bucket.agricam_stockage.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket de logs séparé pour les accès S3 (CKV_AWS_18)
resource "aws_s3_bucket" "agricam_s3_logs" {
  bucket = "agricam-${var.environnement}-logs-camtech-2024"

  tags = {
    Name = "agricam-logs-${var.environnement}"
    Type = "Logs"
  }
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
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "agricam_s3_logging" {
  bucket        = aws_s3_bucket.agricam_stockage.id
  target_bucket = aws_s3_bucket.agricam_s3_logs.id
  target_prefix = "access-logs/"
}
