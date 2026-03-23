##############################################
# PRODUCTION-GRADE ECS on EC2 with Auto Scaling
##############################################

#---------------------------------------------
# 1. ECR Repository (Immutable + Lifecycle)
#---------------------------------------------
resource "aws_ecr_repository" "app_repo" {
  name                 = "webapp-${local.env_suffix}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
  
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, { Name = "ecr-webapp-${local.env_suffix}" })
}

resource "aws_ecr_lifecycle_policy" "app_repo_lifecycle" {
  repository = aws_ecr_repository.app_repo.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# resource "null_resource" "frontend_image" {
#   provisioner "local-exec" {
#     # interpreter = ["/usr/bin/bash", "-lc"]
#     interpreter = ["C:\\Program Files\\Git\\usr\\bin\\bash.exe", "-lc"]
#     command = <<-EOT
#       set -euo pipefail

#       # REGISTRY="513410254332.dkr.ecr.us-east-1.amazonaws.com"
#       # REPOSITORY_URL="513410254332.dkr.ecr.us-east-1.amazonaws.com/webapp-dev"
#       REPOSITORY_URL=${aws_ecr_repository.app_repo.repository_url}
#       REGISTRY="$(echo "$REPOSITORY_URL" | cut -d/ -f1)"
#       # echo "$REGISTRY"
#       # REPOSITORY="webapp-dev"
#       # IMAGE_URI="$REGISTRY/$REPOSITORY::${var.image_tag}"
#       # IMAGE_URI=${aws_ecr_repository.app_repo.repository_url}:${var.image_tag}
#       IMAGE_URI=$REPOSITORY_URL:${var.image_tag}

#       aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY"
#       docker build -t frontend ../frontend
#       docker tag frontend:latest "$IMAGE_URI"
#       docker push "$IMAGE_URI"
#     EOT
#   }
# }


#---------------------------------------------
# 2. CloudWatch Log Group
#---------------------------------------------
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/webapp-${local.env_suffix}"
  retention_in_days = 30 
  tags              = local.common_tags
}

#---------------------------------------------
# 3. IAM Roles (Tasks, Execution, and EC2 Nodes)
#---------------------------------------------
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution Role (For the ECS Agent on the task)
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecsTaskExecutionRole-${local.env_suffix}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task Role (For Application Code)
resource "aws_iam_role" "ecs_task_role" {
  name               = "ecsTaskRole-${local.env_suffix}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

# Allow Execution role to read Secrets Manager
resource "aws_iam_policy" "ecs_task_secrets_policy" {
  name = "ecsTaskSecretsPolicy-${local.env_suffix}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["secretsmanager:GetSecretValue"]
      Effect   = "Allow"
      Resource = [aws_secretsmanager_secret.app_secret.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_secrets_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_secrets_policy.arn
}

# NEW: IAM Role & Profile for the underlying EC2 Instances
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_node_role" {
  name               = "ecsNodeRole-${local.env_suffix}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_node_role_policy" {
  role       = aws_iam_role.ecs_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_node_profile" {
  name = "ecsNodeProfile-${local.env_suffix}"
  role = aws_iam_role.ecs_node_role.name
}


# 1. The Policy that allows your Node.js app to query ECS
resource "aws_iam_policy" "ecs_metadata_policy" {
  name        = "ECSMetadataAccessPolicy"
  description = "Allows the Express app to describe tasks and container instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTasks",
          "ecs:DescribeContainerInstances"
        ]
        # Restrict this to your specific cluster for security
        Resource = [
          "arn:aws:ecs:${var.region}:${var.account_id}:task/${aws_ecs_cluster.app_cluster.name}/*",
          "arn:aws:ecs:${var.region}:${var.account_id}:container-instance/${aws_ecs_cluster.app_cluster.name}/*"
        ]
      }
    ]
  })
}

# 2. Attach it to your Task Role (Ensure your ecs_task_role exists!)
resource "aws_iam_role_policy_attachment" "ecs_metadata_attach" {
  role       = aws_iam_role.ecs_task_role.name 
  policy_arn = aws_iam_policy.ecs_metadata_policy.arn
}
#---------------------------------------------
# 4. Secrets Manager 
#---------------------------------------------
resource "aws_secretsmanager_secret" "app_secret" {
  name                    = "${var.project_name}-secret"
  description             = "Application secret key container"
  recovery_window_in_days = 0 
  tags = merge(local.common_tags, { Name = "${var.project_name}-secret" })
}

# resource "aws_secretsmanager_secret_version" "app_secret_version" {
#   secret_id = aws_secretsmanager_secret.app_secret.id
#   secret_string = jsonencode({
#     APP_SECRET_KEY = "${var.secret_key}"

#   })
# }



#---------------------------------------------
# 5. Security Groups
#---------------------------------------------

# security group for alb
resource "aws_security_group" "alb_sg" {
  name        = "alb security group"
  description = "enable http/https access on port 80/443"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "http access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "https access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "alb_sg"
  })
}


# Task SG (For the individual containers running in awsvpc mode)
resource "aws_security_group" "app_task_sg" {
  name        = "webapp-task-sg-${local.env_suffix}"
  description = "SG for ECS tasks"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "http port access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "allow_alb_to_tasks" {
  type                     = "ingress"
  from_port                = 3200
  to_port                  = 3200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app_task_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
}
# resource "aws_vpc_security_group_ingress_rule" "allow_http" {
#   security_group_id = aws_security_group.app_task_sg.id
#   cidr_ipv4         = "0.0.0.0/0"
#   from_port         = 80
#   ip_protocol       = "tcp"
#   to_port           = 80
# }


# NEW: Node SG (For the underlying EC2 instances to talk to AWS endpoints)
resource "aws_security_group" "ecs_node_sg" {
  name        = "ecs-node-sg-${local.env_suffix}"
  description = "SG for ECS EC2 nodes"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    description = "node port access"
    from_port   = 3200
    to_port     = 3200
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "node port access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#---------------------------------------------
# 6. EC2 Auto Scaling Group & Launch Template
#---------------------------------------------
# Dynamically fetch the latest Amazon Linux 2023 ECS-Optimized AMI
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "ecs-template-${local.env_suffix}"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  # instance_type = "t3.medium"
  instance_type = "c7i-flex.large"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_node_profile.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_node_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.app_cluster.name} >> /etc/ecs/ecs.config
  EOF
  )
}

resource "aws_autoscaling_group" "ecs_asg" {
  name                = "ecs-asg-${local.env_suffix}"
  vpc_zone_identifier = [aws_subnet.pub_sub_1a.id, aws_subnet.pub_sub_2b.id]
  
  min_size         = 1
  max_size         = 5
  desired_capacity = 1

  launch_template {
    id      = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}

#---------------------------------------------
# 7. ECS Cluster & Capacity Provider
#---------------------------------------------
resource "aws_ecs_cluster" "app_cluster" {
  name = "ecs-cluster-${local.env_suffix}"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.common_tags
}

resource "aws_ecs_capacity_provider" "ec2_provider" {
  name = "ec2-capacity-provider-${local.env_suffix}"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs_asg.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100 
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster_attach" {
  cluster_name = aws_ecs_cluster.app_cluster.name
  capacity_providers = [aws_ecs_capacity_provider.ec2_provider.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.ec2_provider.name
  }
}

#---------------------------------------------
# 8. Route 53 & ACM Certificate (HTTPS)
#---------------------------------------------
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "app_cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "app_cert_wait" {
  certificate_arn         = aws_acm_certificate.app_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "app_alias" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.app_alb.dns_name
    zone_id                = aws_lb.app_alb.zone_id
    evaluate_target_health = true
  }
}

#---------------------------------------------
# 9. ALB + Target Group + Listener
#---------------------------------------------
resource "aws_lb" "app_alb" {
  name               = "alb-${local.env_suffix}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.pub_sub_1a.id, aws_subnet.pub_sub_2b.id]
  # enable_deletion_protection = true 
}

resource "aws_lb_target_group" "app_tg" {
  # name        = "tg-${local.env_suffix}"
  # 2. ADD 'name_prefix' (Must be 6 characters or less)
  # alway use name_prefix when we have to create and destroy the same resource
  name_prefix          = "tg-${local.env_suffix}"
  port        = 3200
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "ip" # Must be 'ip' when using awsvpc network mode

  # ADD THIS LINE: Lower the wait time from 5 minutes to 30 seconds
  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 5
    unhealthy_threshold = 3
    timeout             = 15
    interval            = 30
    matcher             = "200-399"
  }
  # 3. ADD THIS LIFECYCLE BLOCK
  lifecycle {
    create_before_destroy = true
  }
}

# Redirect HTTP to HTTPS
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Secure HTTPS Listener
resource "aws_lb_listener" "app_listener_https_secure" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate_validation.app_cert_wait.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

#---------------------------------------------
# 10. ECS Task Definition
#---------------------------------------------
resource "aws_ecs_task_definition" "app_task" {
  family                   = "webapp-task-${local.env_suffix}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"] # Changed from FARGATE
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn 

  container_definitions = jsonencode([
    {
      name      = "webapp"
      # image     = "${aws_ecr_repository.app_repo.repository_url}:latest" 
      image     = "httpd:2.4-alpine" # Bootstrapping image
      essential = true

      portMappings = [{
        containerPort = 3200
        protocol      = "tcp"
      }]

      environment = [{
        name  = "ENV"
        value = local.env_suffix
      }]

      secrets = [{
        name      = "APP_SECRET"
        valueFrom = aws_secretsmanager_secret.app_secret.arn
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

#---------------------------------------------
# 11. ECS Service
#---------------------------------------------
resource "aws_ecs_service" "app_service" {
  name             = "webapp-service-${local.env_suffix}"
  cluster          = aws_ecs_cluster.app_cluster.id
  task_definition  = aws_ecs_task_definition.app_task.arn
  desired_count    = var.desired_count

  # ADD THIS: Force Terraform to give up faster if AWS hangs
  timeouts {
    delete = "5m" 
  }
  # Removed launch_type = "FARGATE", replaced with Capacity Provider Strategy
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_provider.name
    weight            = 100
  }

  network_configuration {
    subnets          = [aws_subnet.pub_sub_1a.id, aws_subnet.pub_sub_2b.id] 
    security_groups  = [aws_security_group.app_task_sg.id]
    assign_public_ip = false 
  }

  # ADD THIS LINE: Give the container 60 seconds to boot before the ALB checks it
  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "webapp"
    container_port   = 3200
  }

  deployment_minimum_healthy_percent = 100 
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [
      task_definition,
      desired_count
    ]
  }

  depends_on = [
    aws_lb_listener.app_listener_https_secure,
    aws_ecs_cluster_capacity_providers.cluster_attach # Ensure CP is attached before Service uses it
  ]
}

#---------------------------------------------
# 12. Application Auto Scaling (Task Level)
#---------------------------------------------
resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.app_cluster.name}/${aws_ecs_service.app_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Auto-scale tasks based on CPU Utilization
resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
  name               = "webapp-cpu-autoscaling-${local.env_suffix}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
