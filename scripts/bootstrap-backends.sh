#!/bin/bash
# ============================================================
# Bootstrap Terraform remote state backends
# Run ONCE before first terraform init
# ============================================================
set -e

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $AWS_ACCOUNT"

create_backend() {
  local REGION=$1
  local SUFFIX=$2
  local BUCKET="healthcare-tfstate-${SUFFIX}"
  local TABLE="terraform-lock-${SUFFIX}"

  echo ""
  echo "=== Creating backend for $REGION ($SUFFIX) ==="

  # S3 bucket
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    echo "Bucket $BUCKET already exists"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION") \
      --no-cli-pager

    aws s3api put-bucket-versioning \
      --bucket "$BUCKET" \
      --versioning-configuration Status=Enabled \
      --region "$REGION"

    aws s3api put-bucket-encryption \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --server-side-encryption-configuration '{
        "Rules": [{
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "aws:kms"
          }
        }]
      }'

    aws s3api put-public-access-block \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    echo "✅ Bucket $BUCKET created"
  fi

  # DynamoDB lock table
  if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
    echo "Table $TABLE already exists"
  else
    aws dynamodb create-table \
      --table-name "$TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION" \
      --no-cli-pager
    echo "✅ DynamoDB table $TABLE created"
  fi
}

create_backend "ap-south-1" "india"
create_backend "eu-west-1"  "europe"
create_backend "us-east-1"  "usa"
create_backend "us-east-1"  "global"

echo ""
echo "✅ All backends ready. You can now run terraform init in each infra/ subdirectory."
