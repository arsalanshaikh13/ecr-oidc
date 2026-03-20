##############################################
# Data Sources
##############################################

# Get current AWS account details
data "aws_caller_identity" "current" {}

# Get default VPC info (optional)
# data "aws_vpc" "default" {
#   default = true
# }

# Get region details
data "aws_region" "current" {}