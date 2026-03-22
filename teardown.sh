#!/bin/bash

# ==========================================================
# Configuration: Update these to match your environment
# ==========================================================
CLUSTER_NAME="ecs-cluster-dev"
SERVICE_NAME="webapp-service-dev"
ASG_NAME="ecs-asg-dev"
REGION="us-east-1"

echo "======================================================"
echo " 🛑 Initiating Safe ECS Teardown Sequence..."
echo "======================================================"

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

# Step 3: Terminate the EC2 Instances
echo "3️⃣ Scaling Auto Scaling Group ($ASG_NAME) to 0 instances..."
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 0 \
  --max-size 0 \
  --desired-capacity 0 \
  --region "$REGION" > /dev/null

if [ $? -ne 0 ]; then
  echo "⚠️ Failed to update ASG. It may have already been deleted."
else
  echo "✅ EC2 instances are terminating..."
  # Give AWS a few seconds to register the termination state before Terraform hits the API
  sleep 10
fi

# Extract the raw Instance IDs attached to the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text)

if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
  echo "   🔥 Target(s) acquired: $INSTANCE_IDS"
  echo "   ☠️  Sending termination signal..."
  
  # Forcefully terminate the instances via EC2 API
  aws ec2 terminate-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$REGION" > /dev/null
    
  echo "   ⏳ Waiting for AWS to confirm termination (usually takes ~30 seconds)..."
  
  # This command pauses the script until AWS confirms the instances are physically dead
  aws ec2 wait instance-terminated \
    --instance-ids $INSTANCE_IDS \
    --region "$REGION"
    
  echo "   ✅ All EC2 instances successfully destroyed."
else
  echo "   ✅ No running instances found."
fi

# Step 3: Trigger Terraform
echo "======================================================"
echo " 🌪️  Infrastructure is clear. Triggering Terraform... "
echo "======================================================"

# We use the standard command so you still get the [yes/no] safety prompt
terraform destroy -var-file=dev.tfvars -auto-approve