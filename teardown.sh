#!/bin/bash

# ==========================================================
# Configuration: Update these to match your environment
# ==========================================================
CLUSTER_NAME="ecs-cluster-dev"
SERVICE_NAME="webapp-service-dev"
REGION="us-east-1"
TARGET_GROUP_NAME="tg-dev" # Update this to match your exact Target Group name

echo "======================================================"
echo " 🛑 Initiating Safe ECS Teardown Sequence..."
echo "======================================================"

# Step 1: Remove the Load Balancer's safety net
echo "1️⃣ Modifying Target Group ($TARGET_GROUP_NAME) to drop connections instantly..."

# Retrieve the exact ARN of the Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_NAME" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null)

if [ -n "$TG_ARN" ]; then
  # Force the draining delay to 0 seconds
  aws elbv2 modify-target-group-attributes \
    --target-group-arn "$TG_ARN" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=0 \
    --region "$REGION" > /dev/null
  echo "   ✅ Deregistration delay set to 0. Safety nets removed."
else
  echo "⚠️ Target Group not found (It may already be deleted). Proceeding..."
fi

# Step 1: Tell AWS to drain the tasks
echo "1️⃣ Scaling $SERVICE_NAME to 0 tasks..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --desired-count 0 \
  --region "$REGION" > /dev/null

if [ $? -ne 0 ]; then
  echo "❌ Failed to update the ECS service. Please check your AWS credentials and cluster name."
  exit 1
fi

# Step 2: Actively monitor the shutdown process
echo "2️⃣ Waiting for all running tasks to terminate cleanly..."
while true; do
  # Query AWS for the exact number of running tasks
  RUNNING_TASKS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' \
    --output text)

  # Check if the query returned a valid number (handles "service not found" edge cases)
  if [[ ! "$RUNNING_TASKS" =~ ^[0-9]+$ ]]; then
    echo "⚠️ Could not retrieve task count. The service might already be deleted."
    break
  fi

  if [ "$RUNNING_TASKS" -eq 0 ]; then
    echo "✅ All tasks have been successfully terminated."
    break
  else
    echo "   ⏳ Still draining... ($RUNNING_TASKS tasks remaining). Checking again in 10 seconds."
    sleep 10
  fi
done

# force delete the service
aws ecs delete-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --region "$REGION" \
  --force \
  --no-cli-pager

aws ecs delete-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --region "$REGION" \
  --no-cli-pager
# Step 3: Trigger Terraform
echo "======================================================"
echo " 🌪️  Infrastructure is clear. Triggering Terraform... "
echo "======================================================"

# We use the standard command so you still get the [yes/no] safety prompt
terraform destroy -var-file=dev.tfvars -parallelism=20 -auto-approve 