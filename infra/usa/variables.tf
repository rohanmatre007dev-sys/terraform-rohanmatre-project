variable "aws_region" { default = "us-east-1" }
variable "environment" { default = "prod" }
variable "vpc_cidr" { default = "10.2.0.0/16" }
variable "public_subnet_cidrs" { default = ["10.2.1.0/24", "10.2.2.0/24"] }
variable "private_subnet_cidrs" { default = ["10.2.3.0/24", "10.2.4.0/24"] }
variable "ami_id" { type = string }
variable "instance_type" { default = "t3.medium" }
variable "key_name" { type = string }
variable "bastion_cidr" { default = "10.0.0.0/8" }
variable "db_instance_class" { default = "db.t3.medium" }
variable "db_name" { default = "healthcare_usa" }
variable "db_username" {
  default   = "healthcare_admin"
  sensitive = true
}
variable "ecr_registry" { type = string }
variable "india_alb_dns" { default = "" }
variable "europe_alb_dns" { default = "" }
