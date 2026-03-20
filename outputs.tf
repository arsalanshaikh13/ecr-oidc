##############################################
# Outputs
##############################################

output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.app_repo.repository_url
}

output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.app_cluster.name
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.app_alb.dns_name
}

output "service_name" {
  description = "ECS Service name"
  value       = aws_ecs_service.app_service.name
}

output "task_role_arn" {
  description = "Task Execution Role ARN"
  value       = aws_iam_role.ecs_task_execution_role.arn
}
output "ecr_registry_id" {
  description = "ecr_repo registry id"
  value       = aws_ecr_repository.app_repo.registry_id
}
output "ecr_repo_url" {
  description = "ecr_repo repo url"
  value       = aws_ecr_repository.app_repo.repository_url
}