variable "circleci_org_id" {
  description = "Your CircleCI Organization ID (UUID format)"
  type        = string
  default = "f79cbd80-b114-44b6-a924-278fb156aa9f"
}

variable "circleci_project_ecr-oidc" {
  description = "Your CircleCI Project ID (UUID format)"
  type        = string
  default = "413fd03c-f481-4745-ab03-76f15d34348e"
}
variable "circleci_project-ecr-oidc-multiple-service" {
  description = "Your CircleCI Project ID (UUID format)"
  type        = string
  default = "e73fb788-9f2d-4822-b5bc-c2460a9bcda2"
}
# ---------------------------------------------------------
# 1. Fetch CircleCI's TLS Certificate Thumbprint
# ---------------------------------------------------------
# Notice the URL explicitly requires your Organization ID
data "tls_certificate" "circleci" {
  url = "https://oidc.circleci.com/org/${var.circleci_org_id}"
}

# get current region
data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
}
# ---------------------------------------------------------
# 2. Create the CircleCI OIDC Identity Provider in AWS
# ---------------------------------------------------------
resource "aws_iam_openid_connect_provider" "circleci" {
  url             = "https://oidc.circleci.com/org/${var.circleci_org_id}"
  client_id_list  = [var.circleci_org_id] # CircleCI uses your Org ID as the Audience
  thumbprint_list = [data.tls_certificate.circleci.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------
# 3. Create the IAM Role for CircleCI (The Gatekeeper)
# ---------------------------------------------------------
resource "aws_iam_role" "circleci_actions_role" {
  name = "CircleCIActions-ECS-DeployRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.circleci.arn
        }
        Condition = {
          # REQUIREMENT 1: The token must be intended for your CircleCI Org
          "StringEquals": {
            "oidc.circleci.com/org/${var.circleci_org_id}:aud": var.circleci_org_id
          },
          # REQUIREMENT 2: The request MUST come from your specific project
          # The format is: org/ORG_ID/project/PROJECT_ID/user/USER_ID
          "StringLike": {
            "oidc.circleci.com/org/${var.circleci_org_id}:sub": ["org/${var.circleci_org_id}/project/${var.circleci_project_ecr-oidc}/user/*", 
                                                                 "org/${var.circleci_org_id}/project/${var.circleci_project-ecr-oidc-multiple-service}/user/*"
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
# Give CircleCI permission to push images to ECR
resource "aws_iam_role_policy_attachment" "circleci_ecr_access" {
  role       = aws_iam_role.circleci_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Give CircleCI permission to update ECS Services
resource "aws_iam_role_policy_attachment" "circleci_ecs_access" {
  role       = aws_iam_role.circleci_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# Give CircleCI permission to create/update AWS Secrets Manager
resource "aws_iam_policy" "circleci_secrets_policy" {
  name = "CircleCISecretsManagerDeployPolicy"
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

resource "aws_iam_role_policy_attachment" "circleci_secrets_attach" {
  role       = aws_iam_role.circleci_actions_role.name
  policy_arn = aws_iam_policy.circleci_secrets_policy.arn
}

# Fetch the current AWS Account ID dynamically for the secrets policy
data "aws_caller_identity" "current" {}