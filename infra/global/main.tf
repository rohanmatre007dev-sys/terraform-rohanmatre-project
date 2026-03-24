# =============================================================
# GLOBAL — Route53 Failover & Health Checks
# Deploy LAST — after india, europe, usa are applied
# =============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0, < 7.0" }
  }
  backend "s3" {
    bucket  = "healthcare-tfstate-global"
    key     = "global/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# =============================================================
# Remote state — read ALB outputs from each region
# =============================================================
data "terraform_remote_state" "india" {
  backend = "s3"
  config = {
    bucket = "healthcare-tfstate-india"
    key    = "india/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "europe" {
  backend = "s3"
  config = {
    bucket = "healthcare-tfstate-europe"
    key    = "europe/terraform.tfstate"
    region = "eu-west-1"
  }
}

data "terraform_remote_state" "usa" {
  backend = "s3"
  config = {
    bucket = "healthcare-tfstate-usa"
    key    = "usa/terraform.tfstate"
    region = "us-east-1"
  }
}

# =============================================================
# Route53 Health Checks — native resources (wrapper has no health_checks var)
# =============================================================
resource "aws_route53_health_check" "india" {
  fqdn              = data.terraform_remote_state.india.outputs.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = { Name = "india-health-check" }
}

resource "aws_route53_health_check" "europe" {
  fqdn              = data.terraform_remote_state.europe.outputs.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = { Name = "europe-health-check" }
}

resource "aws_route53_health_check" "usa" {
  fqdn              = data.terraform_remote_state.usa.outputs.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = { Name = "usa-health-check" }
}

# =============================================================
# Route53 — rohanmatre007dev-sys/route53/rohanmatre
# var: name (hosted zone name), create_zone = false (zone exists)
#      records = MAP of objects (NOT a list!)
# =============================================================
module "route53" {
  source  = "app.terraform.io/o-aws-ia-l59wi0b2/route53/rohanmatre"
  version = "~> 1.0"

  name        = var.domain_name
  create_zone = false

  records = {
    india = {
      type            = "A"
      name            = "healthcare"
      set_identifier  = "india"
      health_check_id = aws_route53_health_check.india.id
      latency_routing_policy = {
        region = "ap-south-1"
      }
      alias = {
        name                   = data.terraform_remote_state.india.outputs.alb_dns_name
        zone_id                = data.terraform_remote_state.india.outputs.alb_zone_id
        evaluate_target_health = true
      }
    }
    europe = {
      type            = "A"
      name            = "healthcare"
      set_identifier  = "europe"
      health_check_id = aws_route53_health_check.europe.id
      latency_routing_policy = {
        region = "eu-west-1"
      }
      alias = {
        name                   = data.terraform_remote_state.europe.outputs.alb_dns_name
        zone_id                = data.terraform_remote_state.europe.outputs.alb_zone_id
        evaluate_target_health = true
      }
    }
    usa = {
      type            = "A"
      name            = "healthcare"
      set_identifier  = "usa"
      health_check_id = aws_route53_health_check.usa.id
      latency_routing_policy = {
        region = "us-east-1"
      }
      alias = {
        name                   = data.terraform_remote_state.usa.outputs.alb_dns_name
        zone_id                = data.terraform_remote_state.usa.outputs.alb_zone_id
        evaluate_target_health = true
      }
    }
  }
}

# =============================================================
# Variables
# =============================================================
variable "domain_name" {
  type        = string
  description = "Your root domain e.g. rohanmatre.in"
}

variable "hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone ID e.g. Z0569585769TE567SV2Y"
}

# =============================================================
# Outputs
# =============================================================
output "api_endpoint" {
  value = "healthcare.${var.domain_name}"
}

output "india_health_check_id" {
  value = aws_route53_health_check.india.id
}

output "europe_health_check_id" {
  value = aws_route53_health_check.europe.id
}

output "usa_health_check_id" {
  value = aws_route53_health_check.usa.id
}
