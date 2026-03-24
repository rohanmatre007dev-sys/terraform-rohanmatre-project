#!/bin/bash
# ============================================================
# Manual deploy script — deploy to a specific region
# Usage: ./scripts/deploy-region.sh india|europe|usa [image_tag]
# ============================================================
set -e

REGION_ARG=${1:-"all"}
IMAGE_TAG=${2:-"latest"}

deploy_region() {
  local REGION_NAME=$1
  local AWS_REGION=$2
  local TF_DIR="infra/$REGION_NAME"

  echo ""
  echo "======================================================"
  echo " Deploying to $REGION_NAME ($AWS_REGION)"
  echo " Image tag: $IMAGE_TAG"
  echo "======================================================"

  # Get EC2 instance IDs from Terraform output
  INSTANCE_IDS=$(cd "$TF_DIR" && terraform output -json ec2_instance_ids | jq -r '.[]')

  for INSTANCE_ID in $INSTANCE_IDS; do
    echo "→ Deploying to $INSTANCE_ID..."
    COMMAND_ID=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=[
        'cd /opt/healthcare',
        'sed -i \"s|:latest|:$IMAGE_TAG|g\" docker-compose.yml',
        'aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin \$(grep ECR_REGISTRY .env | cut -d= -f2)',
        'docker-compose pull',
        'docker-compose up -d --remove-orphans',
        'docker image prune -f',
        'echo Deploy complete on \$(hostname)'
      ]" \
      --query "Command.CommandId" \
      --output text)

    echo "  Command ID: $COMMAND_ID"
    aws ssm wait command-executed \
      --command-id "$COMMAND_ID" \
      --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION"

    STATUS=$(aws ssm get-command-invocation \
      --command-id "$COMMAND_ID" \
      --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION" \
      --query "Status" --output text)

    if [ "$STATUS" = "Success" ]; then
      echo "  ✅ $REGION_NAME / $INSTANCE_ID — deployed"
    else
      echo "  ❌ $REGION_NAME / $INSTANCE_ID — FAILED (status: $STATUS)"
      aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "StandardErrorContent" --output text
      exit 1
    fi
  done

  # Health check
  ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name)
  echo "→ Health check: http://$ALB_DNS/health"
  for i in {1..8}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" || echo "000")
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "  ✅ $REGION_NAME health check passed"
      return 0
    fi
    echo "  Attempt $i/8: status=$HTTP_STATUS, retrying..."
    sleep 10
  done
  echo "  ❌ $REGION_NAME health check failed"
  exit 1
}

case "$REGION_ARG" in
  india)  deploy_region "india"  "ap-south-1" ;;
  europe) deploy_region "europe" "eu-west-1"  ;;
  usa)    deploy_region "usa"    "us-east-1"  ;;
  all)
    deploy_region "india"  "ap-south-1" &
    deploy_region "europe" "eu-west-1"  &
    deploy_region "usa"    "us-east-1"  &
    wait
    echo ""
    echo "✅ All regions deployed"
    ;;
  *)
    echo "Usage: $0 india|europe|usa|all [image_tag]"
    exit 1
    ;;
esac
