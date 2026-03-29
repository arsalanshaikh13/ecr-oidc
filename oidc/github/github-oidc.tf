# ---------------------------------------------------------
# 1. Fetch GitHub's TLS Certificate Thumbprint
# ---------------------------------------------------------
# AWS needs this to verify the cryptographic signature of GitHub's tokens
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# get current region
data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
}

# ---------------------------------------------------------
# 2. Create the GitHub OIDC Identity Provider in AWS
# ---------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------
# 3. Create the IAM Role for GitHub Actions (The Gatekeeper)
# ---------------------------------------------------------
resource "aws_iam_role" "github_actions_role" {
  name = "GitHubActions-ECS-DeployRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          # REQUIREMENT 1: The token must be intended for AWS STS
          "StringEquals": {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          },
          # REQUIREMENT 2: The request MUST come from your specific repo
          "StringLike": {
            "token.actions.githubusercontent.com:sub": [
                        "repo:arsalanshaikh13/ecr-oidc:*",
                        "repo:arsalanshaikh13/ecr-oidc:*",
                        "repo:arsalanshaikh13/ecr-oidc-multi-service:*",
                        "repo:arsalanshaikh13/ecr-oidc-nextjs:*"
                    ]
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------
# 4. Attach Deployment Permissions to the Role
# ---------------------------------------------------------
# Give GitHub permission to push images to ECR
resource "aws_iam_role_policy_attachment" "github_ecr_access" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Give GitHub permission to update ECS Services
resource "aws_iam_role_policy_attachment" "github_ecs_access" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# Give GitHub permission to create/update AWS Secrets Manager
resource "aws_iam_policy" "github_secrets_policy" {
  name = "GitHubSecretsManagerDeployPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret"
      ]
      Effect   = "Allow"
      Resource = ["arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_secrets_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.github_secrets_policy.arn
}


# Attach this policy to your existing GitHub Actions IAM Role
resource "aws_iam_role_policy" "github_actions_cognito_policy" {
  name = "github-actions-cognito-read-only"
  
  # CHANGE THIS to the actual resource name of your GitHub Actions role in Terraform
  role = aws_iam_role.github_actions_role.id 

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:ListUserPools",
          "cognito-idp:ListUserPoolClients",
          "cognito-idp:DescribeUserPool"
        ]
        # We must use "*" because ListUserPools operates at the account level
        Resource = "*" 
      }
    ]
  })
}


# Fetch the current AWS Account ID dynamically for the secrets policy
data "aws_caller_identity" "current" {}