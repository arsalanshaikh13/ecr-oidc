// Ready-to-copy main.tf with fixes: ensure image pushed before task registration, tasks have egress and ALB ingress, log group exists before task, service waits for image, platform_version set, assign_public_ip=true
##############################################
# ECS Fargate Service with ALB + ECR + Secrets
# Project 3 — Tech Apricate Terraform Series
##############################################


# https://www.youtube.com/watch?v=-vBDxGmQEtY - Terraform AWS Project: Automate ECS, ECR & ALB - Tech Apricate
# https://github.com/bhavukm/terraform-ecs-ecr-alb/blob/master/main.tf


#---------------------------------------------
# 1. ECR Repository
#---------------------------------------------
resource "aws_ecr_repository" "app_repo" {
  name                 = "webapp-${local.env_suffix}"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name = "ecr-webapp-${local.env_suffix}"
  })
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
#   # Use single-line bash command to avoid CRLF/heredoc issues
#   provisioner "local-exec" {
#     command = "bash -lc 'aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app_repo.repository_url} && docker build -t frontend ../frontend && docker tag frontend:latest ${aws_ecr_repository.app_repo.repository_url}:${var.image_tag} && docker push ${aws_ecr_repository.app_repo.repository_url}:${var.image_tag}'"
#   }

#   depends_on = [aws_ecr_repository.app_repo]
# }

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
# 7. CloudWatch Log Group for ECS (create before task)
#---------------------------------------------
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/webapp-${local.env_suffix}"
  retention_in_days = 7
  tags              = local.common_tags
}

#---------------------------------------------
# 2. IAM Role for ECS Task Execution
#---------------------------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecsTaskExecutionRole-${local.env_suffix}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role_policy.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "ecs_task_assume_role_policy" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Attach AWS managed policy for ECS Fargate tasks
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Optional: Allow read access to Secrets Manager (execution role)
data "aws_iam_policy_document" "ecs_task_secrets_policy_doc" {
  statement {
    sid     = "AllowReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      # var.app_secret_arn
      aws_secretsmanager_secret.app_secret.arn
    ]
  }
}

resource "aws_iam_policy" "ecs_task_secrets_policy" {
  name   = "ecsTaskSecretsPolicy-${local.env_suffix}"
  policy = data.aws_iam_policy_document.ecs_task_secrets_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_secrets_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_secrets_policy.arn
}

#---------------------------------------------
# 8. Secret Manager creating secret
#---------------------------------------------

resource "aws_secretsmanager_secret" "app_secret" {
  name        = "${var.project_name}-secret"
  description = " application secret key"
  # kms_key_id  = "alias/aws/secretsmanager" # Or a custom KMS key ARN
  recovery_window_in_days = 0 #force delete,
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-secret"
  })

}

# using ci/cd pipeline to create aws secret
# resource "aws_secretsmanager_secret_version" "app_secret_version" {
#   secret_id = aws_secretsmanager_secret.app_secret.id
#   secret_string = jsonencode({
#     APP_SECRET_KEY = "${var.secret_key}"

#   })
# }


#---------------------------------------------
# New: Security Group for ECS tasks (allows outbound; ALB -> tasks ingress)
#---------------------------------------------
resource "aws_security_group" "app_task_sg" {
  name        = "webapp-task-sg-${local.env_suffix}"
  description = "SG for ECS tasks to allow egress to AWS endpoints; ALB allowed to connect on 80"
  # vpc_id      = var.vpc_id
  vpc_id = aws_vpc.vpc.id
  tags   = local.common_tags

  # no broad ingress here; ALB ingress rule created below
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound for ECR, Secrets Manager, AWS endpoints"
  }

  depends_on = [aws_vpc.vpc]
}

resource "aws_security_group_rule" "allow_alb_to_tasks" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.app_task_sg.id
  # source_security_group_id = var.alb_sg_id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "Allow ALB to reach tasks on port 80"
}


#---------------------------------------------
# 3. ECS Cluster
#---------------------------------------------
resource "aws_ecs_cluster" "app_cluster" {
  name = "ecs-cluster-${local.env_suffix}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

#---------------------------------------------
# 4. ALB + Target Group + Listener
#---------------------------------------------
resource "aws_lb" "app_alb" {
  name               = "alb-${local.env_suffix}"
  internal           = false
  load_balancer_type = "application"
  # security_groups    = [var.alb_sg_id]
  security_groups = [aws_security_group.alb_sg.id]
  # subnets            = var.public_subnets
  subnets = [aws_subnet.pub_sub_1a.id, aws_subnet.pub_sub_2b.id]

  enable_deletion_protection = false

  tags = merge(local.common_tags, {
    Name = "alb-${local.env_suffix}"
  })
  depends_on = [aws_vpc.vpc, aws_security_group.alb_sg]
}

resource "aws_lb_target_group" "app_tg" {
  name     = "tg-${local.env_suffix}"
  port     = 80
  protocol = "HTTP"
  # vpc_id      = var.vpc_id
  vpc_id      = aws_vpc.vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
#---------------------------------------------
# 5. ECS Task Definition
#---------------------------------------------
resource "aws_ecs_task_definition" "app_task" {
  family                   = "webapp-task-${local.env_suffix}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  # ensure the image is pushed and log group exists before registering the task definition
  depends_on = [
    # null_resource.frontend_image,
    aws_cloudwatch_log_group.ecs_log_group
  ]

  container_definitions = jsonencode([
    {
      name      = "webapp"
      # image     = "${aws_ecr_repository.app_repo.repository_url}:${var.image_tag}"
      image     = "httpd:2.4-alpine"
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ENV"
          value = local.env_suffix
        }
      ]

      secrets = [
        {
          name = "APP_SECRET"
          # valueFrom = var.app_secret_arn
          valueFrom = aws_secretsmanager_secret.app_secret.arn
        }
      ]

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
# 6. ECS Service (Fargate)
#---------------------------------------------
resource "aws_ecs_service" "app_service" {
  name             = "webapp-service-${local.env_suffix}"
  cluster          = aws_ecs_cluster.app_cluster.id
  task_definition  = aws_ecs_task_definition.app_task.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

# ADD THIS: Force Terraform to give up faster if AWS hangs
  timeouts {
    delete = "5m" 
  }
  network_configuration {
    # subnets          = var.public_subnets
    subnets = [aws_subnet.pub_sub_1a.id, aws_subnet.pub_sub_2b.id]
    # include task SG (ensures egress); keep user's app_sg_id if additional rules required
    # security_groups  = [aws_security_group.app_task_sg.id, var.app_sg_id]
    security_groups  = [aws_security_group.app_task_sg.id]
    assign_public_ip = true
  }


  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "webapp"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [
    aws_lb_listener.app_listener
    # null_resource.frontend_image
  ]

  # THIS IS THE CRITICAL ADDITION
  lifecycle {
    ignore_changes = [
      task_definition,
      desired_count # Also good to ignore if you plan to use ECS Auto Scaling later
    ]
  }

  tags = local.common_tags
}
