#!/bin/bash

set -euo pipefail

# ---------------------- CONFIGURATION -------------------------
LOG_FILE="../logs/automation.log"
REGION="us-east-1"
SG_NAME="devops-sg"
DESCRIPTION="Security group for Automation Lab"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
# --------------------------------------------------------------

# ---------------------- FUNCTIONS ------------------------------
log() {
  # Logs messages with timestamp and INFO level
  echo "$(date '+%F %T') [INFO] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  # Logs error message and exits
  echo "$(date '+%F %T') [ERROR] $1" | tee -a "$LOG_FILE"
  exit 1
}
# --------------------------------------------------------------

log "Starting Security Group creation process"

# Create the security group
SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "$DESCRIPTION" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text) || error_exit "Failed to create security group"

# Tag the security group for safe identification
aws ec2 create-tags \
  --resources "$SG_ID" \
  --tags Key="$TAG_KEY",Value="$TAG_VALUE"

log "Authorizing inbound rules (SSH & HTTP)"

# Allow SSH access
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

# Allow HTTP access
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

log "Security Group created successfully"
log "Security Group ID: $SG_ID"

aws ec2 describe-security-groups --group-ids "$SG_ID"
