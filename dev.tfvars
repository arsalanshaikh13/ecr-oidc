##############################################
# Dev Environment Variables
##############################################

region       = "us-east-1"
environment  = "dev"
project_name = "ECS-Fargate-ALB"

# Networking
vpc_id          = "vpc-id"
public_subnets  = ["subnet-id1", "subnet-id2"]
vpc_cidr        = "10.0.0.0/16"
pub_sub_1a_cidr = "10.0.1.0/24"
pub_sub_2b_cidr = "10.0.2.0/24"
#private_subnets = ["subnet-ccc333", "subnet-ddd444"]

# Security Groups
alb_sg_id = "sg-id1"
app_sg_id = "sg-id2"

# ECS Configuration
# ECS task sizing
# 256 CPU units = 0.25 vCPU
# 512 MiB       = 0.5 GB
# Smallest valid Fargate size
app_cpu       = 256 # 0.25 vCPU
app_memory    = 512 # 0.5 GB
image_tag     = "latest"
desired_count = 2

# Secret (use ARN of secret in AWS Secrets Manager)
secret_key     = "Secret Key"
app_secret_arn = "arn:aws:secretsmanager:us-east-1:ACCOUNT-ID:secret:APP_SECRET-3vRpHC"