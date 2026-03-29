# ---------------------------------------------------------
# 1. Fetch GitLab's TLS Certificate Thumbprint dynamically
# ---------------------------------------------------------
data "tls_certificate" "gitlab" {
  url = "https://gitlab.com"
}
# get current region
data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
}

# ---------------------------------------------------------
# 2. Create the OIDC Identity Provider in AWS
# ---------------------------------------------------------
resource "aws_iam_openid_connect_provider" "gitlab" {
  url             = "https://gitlab.com"
  client_id_list  = ["https://gitlab.com"]
  thumbprint_list = [data.tls_certificate.gitlab.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------
# 3. Create the IAM Role for GitLab CI/CD (The Gatekeeper)
# ---------------------------------------------------------
resource "aws_iam_role" "gitlab_actions_role" {
  name = "GitLabActions-ECS-DeployRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.gitlab.arn
        }
        Condition = {
          # REQUIREMENT 1: The request must come from GitLab
          "StringEquals" : {
            "gitlab.com:aud" : "https://gitlab.com"
          },
          # REQUIREMENT 2: The request MUST come from your specific repo and branch
          "StringLike" : {
            "gitlab.com:sub" : ["project_path:arsalanshaikh13/ecr-oidc:ref_type:branch:ref:*", "project_path:arsalanshaikh13/ecr-oidc-multiple-service:ref_type:branch:ref:*"]
          }
        }
      }
    ]
  })
}

# Give GitLab permission to push images to ECR
resource "aws_iam_role_policy_attachment" "gitlab_ecr_access" {
  role       = aws_iam_role.gitlab_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Give GitLab permission to update ECS Services
resource "aws_iam_role_policy_attachment" "gitlab_ecs_access" {
  role       = aws_iam_role.gitlab_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# Give GitLab permission to create/update AWS Secrets Manager
resource "aws_iam_policy" "gitlab_secrets_policy" {
  name = "GitLabSecretsManagerDeployPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Effect   = "Allow"
      Resource = ["arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gitlab_secrets_attach" {
  role       = aws_iam_role.gitlab_actions_role.name
  policy_arn = aws_iam_policy.gitlab_secrets_policy.arn
}

# Fetch the current AWS Account ID dynamically for the policy above
data "aws_caller_identity" "current" {}