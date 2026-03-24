output "vpc_id" {
  value = module.vpc.vpc_id
}

output "alb_dns_name" {
  value = module.alb.elb_dns_name
}

output "alb_zone_id" {
  value = module.alb.elb_zone_id
}

output "ec2_instance_ids" {
  value = [module.ec2_az_a.id, module.ec2_az_b.id]
}

output "sns_topic_arn" {
  value = module.sns.topic_arn
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "rds_endpoint" {
  value     = module.rds.db_instance_address
  sensitive = true
}
