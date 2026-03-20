##############################################
# Locals
##############################################

locals {
  environment = var.environment
  env_suffix  = lower(var.environment)

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}