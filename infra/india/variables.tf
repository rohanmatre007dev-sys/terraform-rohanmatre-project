variable "aws_region" {
  description = "AWS region for India deployment"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Deployment environment (dev/staging/prod)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "database_subnet_cidrs" {
  description = "Database subnet CIDRs"
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (Amazon Linux 2023)"
  type        = string
  # Use: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 --region ap-south-1
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "bastion_cidr" {
  description = "CIDR allowed to SSH into EC2 instances"
  type        = string
  default     = "10.0.0.0/8"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "healthcare_india"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "healthcare_admin"
  sensitive   = true
}

variable "ecr_registry" {
  description = "ECR registry URL"
  type        = string
}

variable "europe_alb_dns" {
  description = "Europe ALB DNS for cross-region SNS subscription"
  type        = string
  default     = ""
}

variable "usa_alb_dns" {
  description = "USA ALB DNS for cross-region SNS subscription"
  type        = string
  default     = ""
}
