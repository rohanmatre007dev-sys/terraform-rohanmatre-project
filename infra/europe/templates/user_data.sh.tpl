#!/bin/bash
set -e

# ================================================================
# Healthcare Platform — EC2 Bootstrap Script
# Region: ${region_name}
# ================================================================

# Install Docker & AWS CLI
dnf update -y
dnf install -y docker aws-cli jq

systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -SL "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# ================================================================
# Fetch DB credentials from Secrets Manager
# ================================================================
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${region}" \
  --query SecretString \
  --output text)

DB_HOST=$(echo $SECRET | jq -r '.host')
DB_USER=$(echo $SECRET | jq -r '.username')
DB_PASS=$(echo $SECRET | jq -r '.password')
DB_NAME=$(echo $SECRET | jq -r '.dbname')

# ================================================================
# Write environment file
# ================================================================
cat > /opt/healthcare/.env <<EOF
REGION=${region}
REGION_NAME=${region_name}
DB_HOST=$DB_HOST
DB_PORT=5432
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
SQS_QUEUE_URL=${sqs_url}
SNS_TOPIC_ARN=${sns_topic_arn}
ECR_REGISTRY=${ecr_registry}
EOF

chmod 600 /opt/healthcare/.env

# ================================================================
# Authenticate to ECR and pull images
# ================================================================
aws ecr get-login-password --region ${region} | \
  docker login --username AWS --password-stdin ${ecr_registry}

# ================================================================
# Write docker-compose.yml
# ================================================================
mkdir -p /opt/healthcare
cat > /opt/healthcare/docker-compose.yml <<'COMPOSE'
version: "3.9"

services:
  patient-monitoring:
    image: ${ecr_registry}/patient-monitoring:latest
    restart: always
    ports:
      - "8080:8080"
    env_file: /opt/healthcare/.env
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: awslogs
      options:
        awslogs-region: ${region}
        awslogs-group: /healthcare/${region_name}/patient-monitoring

  emergency-alert:
    image: ${ecr_registry}/emergency-alert:latest
    restart: always
    ports:
      - "8081:8081"
    env_file: /opt/healthcare/.env
    depends_on:
      - patient-monitoring
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8081/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: awslogs
      options:
        awslogs-region: ${region}
        awslogs-group: /healthcare/${region_name}/emergency-alert

  patient-data:
    image: ${ecr_registry}/patient-data:latest
    restart: always
    ports:
      - "8082:8082"
    env_file: /opt/healthcare/.env
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8082/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: awslogs
      options:
        awslogs-region: ${region}
        awslogs-group: /healthcare/${region_name}/patient-data
COMPOSE

# ================================================================
# Start services
# ================================================================
cd /opt/healthcare
docker-compose pull
docker-compose up -d

# ================================================================
# Deploy script for CI/CD SSH deployments
# ================================================================
cat > /opt/healthcare/deploy.sh <<'DEPLOY'
#!/bin/bash
set -e
cd /opt/healthcare
aws ecr get-login-password --region $(curl -s http://169.254.169.254/latest/meta-data/placement/region) | \
  docker login --username AWS --password-stdin $(grep ECR_REGISTRY .env | cut -d= -f2)
docker-compose pull
docker-compose up -d --remove-orphans
docker image prune -f
DEPLOY

chmod +x /opt/healthcare/deploy.sh
echo "Bootstrap complete — ${region_name} ready"
