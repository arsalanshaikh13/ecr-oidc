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

# Task Role (For Application Code)
resource "aws_iam_role" "ecs_task_role" {
  name               = "ecsTaskRole-${local.env_suffix}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role_policy.json
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
resource "aws_iam_role_policy_attachment" "ecs_metadata_attach_exec" {
  # Change this to target the Execution Role, since that is what the log says your app is using!
  role       = aws_iam_role.ecs_task_execution_role.name 
  policy_arn = aws_iam_policy.ecs_metadata_policy.arn
}


#---------------------------------------------
# New: Security Group for ECS tasks (allows outbound; ALB -> tasks ingress)
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

resource "aws_security_group" "app_task_sg" {
  name        = "webapp-task-sg-${local.env_suffix}"
  description = "SG for ECS tasks to allow egress to AWS endpoints; ALB allowed to connect on 3200"
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
  from_port         = 3200
  to_port           = 3200
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
# 7. Route 53 & ACM Certificate (HTTPS)
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
  port     = 3200
  protocol = "HTTP"
  # vpc_id      = var.vpc_id
  vpc_id      = aws_vpc.vpc.id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = local.common_tags
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
# 5. ECS Task Definition
#---------------------------------------------
resource "aws_ecs_task_definition" "app_task" {
  family                   = "webapp-task-${local.env_suffix}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn   
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
          containerPort = 3200
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ENV"
          value = local.env_suffix
        }
      ]
      # ADD THIS: Forces Fargate to only wait 5 seconds before killing the container
      stopTimeout = 5
      
      
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
    container_port   = 3200
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [
    aws_lb_listener.app_listener_https_secure
    # null_resource.frontend_image
  ]

  # THIS IS THE CRITICAL ADDITION
  lifecycle {
    ignore_changes = [
      task_definition,
      # desired_count # Also good to ignore if you plan to use ECS Auto Scaling later
    ]
  }

  tags = local.common_tags
}
