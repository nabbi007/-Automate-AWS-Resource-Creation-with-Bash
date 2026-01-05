#!/bin/bash
# -------------------------------------------------------------
# Script Name : create_ec2.sh
# Purpose     : Launch a free-tier EC2 instance
# Author      : Iliasu Abubakar
# -------------------------------------------------------------

set -euo pipefail

# ---------------------- CONFIGURATION -------------------------
LOG_FILE="../logs/automation.log"
REGION="us-east-1"
AMI_ID="ami-0c02fb55956c7d316"   # Amazon Linux 2 (Free Tier)
INSTANCE_TYPE="t2.micro"
KEY_NAME="automation-key"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
# --------------------------------------------------------------

# ---------------------- FUNCTIONS ------------------------------
log() {
  echo "$(date '+%F %T') [INFO] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  echo "$(date '+%F %T') [ERROR] $1" | tee -a "$LOG_FILE"
  exit 1
}
# --------------------------------------------------------------

log "Creating EC2 key pair"

# Create key pair and store private key securely
aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --query 'KeyMaterial' \
  --output text > "$KEY_NAME.pem"

chmod 400 "$KEY_NAME.pem"

log "Launching EC2 instance"

# Launch EC2 instance
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

log "Waiting for instance to reach RUNNING state"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Retrieve public IP address
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log "EC2 instance created successfully"

echo "--------------------------------------------"
echo "Instance ID : $INSTANCE_ID"
echo "Public IP  : $PUBLIC_IP"
echo "--------------------------------------------"
