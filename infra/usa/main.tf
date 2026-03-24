# =============================================================
# USA REGION — us-east-1
# Org: rohanmatre007dev-sys
# Variable names taken directly from actual wrapper variables.tf
# =============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.0, < 7.0" }
    random = { source = "hashicorp/random", version = ">= 3.0" }
  }
  backend "s3" {
    bucket         = "healthcare-tfstate-usa"
    key            = "usa/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-usa"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "healthcare-monitoring"
      Region      = "usa"
      Environment = var.environment
      ManagedBy   = "terraform"
      Compliance  = "HIPAA"
    }
  }
}

locals {
  region_prefix = "usa"
  az_a          = "${var.aws_region}a"
  az_b          = "${var.aws_region}b"
}

# =============================================================
# VPC
# =============================================================
module "vpc" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/vpc/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-healthcare-vpc"
  cidr        = var.vpc_cidr
  azs         = [local.az_a, local.az_b]
  environment = var.environment

  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway           = true
  single_nat_gateway           = false
  enable_dns_hostnames         = true
  enable_dns_support           = true
  create_database_subnet_group = true # ✅ MUST be present
}

# =============================================================
# SECURITY GROUPS
# =============================================================
module "alb_sg" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/security-group/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-alb-sg"
  description = "ALB SG - HTTP/HTTPS from internet"
  vpc_id      = module.vpc.vpc_id
  environment = var.environment

  ingress_with_cidr_blocks = [
    { from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = "0.0.0.0/0", description = "HTTP" },
    { from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = "0.0.0.0/0", description = "HTTPS" }
  ]
  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
}

module "ec2_sg" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/security-group/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-ec2-sg"
  description = "EC2 SG - traffic from ALB only"
  vpc_id      = module.vpc.vpc_id
  environment = var.environment

  ingress_with_source_security_group_id = [
    { from_port = 8080, to_port = 8080, protocol = "tcp", source_security_group_id = module.alb_sg.security_group_id, description = "App from ALB" },
    { from_port = 8081, to_port = 8081, protocol = "tcp", source_security_group_id = module.alb_sg.security_group_id, description = "Alert from ALB" }
  ]
  ingress_with_cidr_blocks = [
    { from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = var.bastion_cidr, description = "SSH" }
  ]
  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
}

module "rds_sg" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/security-group/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-rds-sg"
  description = "RDS SG - PostgreSQL from EC2 only"
  vpc_id      = module.vpc.vpc_id
  environment = var.environment

  ingress_with_source_security_group_id = [
    { from_port = 5432, to_port = 5432, protocol = "tcp", source_security_group_id = module.ec2_sg.security_group_id, description = "PostgreSQL" }
  ]
  egress_rules = []
}

# =============================================================
# IAM
# =============================================================
module "ec2_iam_profile" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/iam/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name                    = "${local.region_prefix}-ec2-role"
  environment             = var.environment
  create_instance_profile = true

  trust_policy_permissions = {
    EC2AssumeRole = {
      actions    = ["sts:AssumeRole"]
      principals = [{ type = "Service", identifiers = ["ec2.amazonaws.com"] }]
    }
  }

  policies = {
    SSM        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ECR        = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    CloudWatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  inline_policy_statements = {
    secrets = {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [aws_secretsmanager_secret.db_credentials.arn]
    }
    sns_publish = {
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [module.sns.topic_arn]
    }
    sqs_access = {
      effect    = "Allow"
      actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
      resources = [module.sqs.queue_arn]
    }
  }
}

# =============================================================
# EC2
# =============================================================
module "ec2_az_a" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/ec2-instance/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-healthcare-ec2-az-a"
  environment = var.environment

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [module.ec2_sg.security_group_id]
  key_name               = var.key_name
  iam_instance_profile   = module.ec2_iam_profile.instance_profile_name

  user_data_base64 = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    ecr_registry  = var.ecr_registry
    region        = var.aws_region
    db_host       = module.rds.db_instance_address
    db_name       = var.db_name
    db_secret_arn = aws_secretsmanager_secret.db_credentials.arn
    sqs_url       = module.sqs.queue_url
    sns_topic_arn = module.sns.topic_arn
    region_name   = "USA"
  }))

  root_block_device = { size = 30, type = "gp3" }
  tags              = { AZ = local.az_a, Role = "app-server" }
}

module "ec2_az_b" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/ec2-instance/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-healthcare-ec2-az-b"
  environment = var.environment

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnet_ids[1]
  vpc_security_group_ids = [module.ec2_sg.security_group_id]
  key_name               = var.key_name
  iam_instance_profile   = module.ec2_iam_profile.instance_profile_name

  user_data_base64 = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    ecr_registry  = var.ecr_registry
    region        = var.aws_region
    db_host       = module.rds.db_instance_address
    db_name       = var.db_name
    db_secret_arn = aws_secretsmanager_secret.db_credentials.arn
    sqs_url       = module.sqs.queue_url
    sns_topic_arn = module.sns.topic_arn
    region_name   = "USA"
  }))

  root_block_device = { size = 30, type = "gp3" }
  tags              = { AZ = local.az_b, Role = "app-server" }
}

# =============================================================
# ALB (Classic ELB wrapper)
# =============================================================
module "alb" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/alb-nlb/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name        = "${local.region_prefix}-healthcare-alb"
  environment = var.environment
  internal    = false

  subnets         = module.vpc.public_subnet_ids
  security_groups = [module.alb_sg.security_group_id]

  listener = [
    {
      instance_port     = 8080
      instance_protocol = "HTTP"
      lb_port           = 80
      lb_protocol       = "HTTP"
    }
  ]

  health_check = {
    target              = "HTTP:8080/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  instances = [module.ec2_az_a.id, module.ec2_az_b.id]

  connection_draining         = true
  connection_draining_timeout = 300
}

# =============================================================
# RDS
# =============================================================
module "rds" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/rds/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  identifier     = "${local.region_prefix}-healthcare-db"
  engine         = "postgres"
  engine_version = "16.6"
  instance_class = var.db_instance_class
  family         = "postgres16"

  allocated_storage     = 100
  max_allocated_storage = 500
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = var.db_name
  username                    = var.db_username
  password_wo                 = random_password.db_password.result
  password_wo_version         = 1 # ✅ ADD THIS LINE
  manage_master_user_password = false

  vpc_security_group_ids = [module.rds_sg.security_group_id]
  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnet_ids
  depends_on             = [module.vpc]

  multi_az                = true
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection          = var.environment == "prod" ? true : false
  skip_final_snapshot          = var.environment == "prod" ? false : true
  performance_insights_enabled = true
  monitoring_interval          = 60
  create_monitoring_role       = false                                                # ← change to false
  monitoring_role_arn          = "arn:aws:iam::075995348852:role/rds-monitoring-role" # ← add this

  parameters = [
    { name = "log_connections", value = "1" },
    { name = "log_disconnections", value = "1" },
    { name = "log_duration", value = "1" }
  ]
}

# =============================================================
# SNS
# =============================================================
module "sns" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/sns/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name         = "${local.region_prefix}-emergency-alerts"
  display_name = "Healthcare Emergency Alerts - USA"

  subscriptions = {
    sqs_local = {
      protocol               = "sqs"
      endpoint               = module.sqs.queue_arn
      endpoint_auto_confirms = true
    }
    # https_india = {
    #   protocol               = "https"
    #   endpoint               = "https://${var.india_alb_dns}/alerts/receive"
    #   endpoint_auto_confirms = true
    # }
    # https_europe = {
    #   protocol               = "https"
    #   endpoint               = "https://${var.europe_alb_dns}/alerts/receive"
    #   endpoint_auto_confirms = true
    # }
  }
}

# =============================================================
# SQS
# =============================================================
module "sqs" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/sqs/rohanmatre"
  version = "~> 1.0"

  region = var.aws_region

  name                       = "${local.region_prefix}-alert-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20
  create_dlq                 = true
}

# =============================================================
# CloudWatch (one module call per resource)
# =============================================================
module "cw_log_monitoring" {
  source                      = "app.terraform.io/o-aws-ia-l59wi0b2/cloudwatch/rohanmatre"
  version                     = "~> 1.0"
  create_log_group            = true
  log_group_name              = "/healthcare/usa/patient-monitoring"
  log_group_retention_in_days = 30
}

module "cw_log_alert" {
  source                      = "app.terraform.io/o-aws-ia-l59wi0b2/cloudwatch/rohanmatre"
  version                     = "~> 1.0"
  create_log_group            = true
  log_group_name              = "/healthcare/usa/emergency-alert"
  log_group_retention_in_days = 30
}

module "cw_log_data" {
  source                      = "app.terraform.io/o-aws-ia-l59wi0b2/cloudwatch/rohanmatre"
  version                     = "~> 1.0"
  create_log_group            = true
  log_group_name              = "/healthcare/usa/patient-data"
  log_group_retention_in_days = 90
}

module "cw_alarm_cpu" {
  source                    = "app.terraform.io/o-aws-ia-l59wi0b2/cloudwatch/rohanmatre"
  version                   = "~> 1.0"
  create_metric_alarm       = true
  alarm_name                = "${local.region_prefix}-high-cpu"
  alarm_comparison_operator = "GreaterThanThreshold"
  alarm_evaluation_periods  = 2
  alarm_metric_name         = "CPUUtilization"
  alarm_namespace           = "AWS/EC2"
  alarm_period              = 120
  alarm_statistic           = "Average"
  alarm_threshold           = 80
  alarm_actions             = [module.sns.topic_arn]
}

module "cw_alarm_rds" {
  source                    = "app.terraform.io/o-aws-ia-l59wi0b2/cloudwatch/rohanmatre"
  version                   = "~> 1.0"
  create_metric_alarm       = true
  alarm_name                = "${local.region_prefix}-rds-connections"
  alarm_comparison_operator = "GreaterThanThreshold"
  alarm_evaluation_periods  = 1
  alarm_metric_name         = "DatabaseConnections"
  alarm_namespace           = "AWS/RDS"
  alarm_period              = 60
  alarm_statistic           = "Average"
  alarm_threshold           = 100
  alarm_actions             = [module.sns.topic_arn]
}

# =============================================================
# Secrets Manager
# =============================================================
resource "random_id" "secret_suffix" {
  byte_length = 2
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.region_prefix}/healthcare/db-credentials-${random_id.secret_suffix.hex}"
  description             = "RDS credentials for USA region"
  recovery_window_in_days = 7
  tags                    = { Region = local.region_prefix }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  depends_on = [module.rds]
  secret_id  = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = module.rds.db_instance_address
    port     = 5432
    dbname   = var.db_name
  })
}

# =============================================================
# Outputs
# =============================================================
output "vpc_id" { value = module.vpc.vpc_id }
output "alb_dns_name" { value = module.alb.elb_dns_name }
output "alb_zone_id" { value = module.alb.elb_zone_id }
output "ec2_instance_ids" { value = [module.ec2_az_a.id, module.ec2_az_b.id] }
output "sns_topic_arn" { value = module.sns.topic_arn }
output "sqs_queue_url" { value = module.sqs.queue_url }
output "rds_endpoint" {
  value     = module.rds.db_instance_address
  sensitive = true
}
