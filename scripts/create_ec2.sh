#!/bin/bash
# AWS EC2 Instance Creation Script - Professional Edition
# Launches EC2 instances with key pair management and logging

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
readonly LOG_FILE="${LOG_DIR}/automation.log"
readonly KEYS_DIR="${SCRIPT_DIR}/../keys"

REGION="${AWS_REGION:-eu-west-1}"
AMI_ID="${AMI_ID:-ami-09c54d172e7aa3d9a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-automation-key}"
KEY_FILE="${KEYS_DIR}/${KEY_NAME}.pem"
INSTANCE_ID=""
PUBLIC_IP=""

# Initialize logging
mkdir -p "$LOG_DIR" "$KEYS_DIR" || { echo "ERROR: Cannot create directories" >&2; exit 1; }
touch "$LOG_FILE" || { echo "ERROR: Cannot create log file" >&2; exit 1; }

log() {
  local level="$1" msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR" "$1"
  if [[ -n "$INSTANCE_ID" ]]; then
    log "WARN" "Cleaning up EC2 instance: $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  fi
  exit 1
}

# Validate prerequisites
if ! command -v aws &>/dev/null; then
  error_exit "AWS CLI is not installed"
fi

if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
  error_exit "AWS credentials not configured or invalid for region: $REGION"
fi

log "INFO" "Starting EC2 instance creation process"
log "INFO" "Region: $REGION, AMI: $AMI_ID, Instance Type: $INSTANCE_TYPE"

# Check if key pair already exists
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  log "INFO" "AWS key pair '$KEY_NAME' already exists"
  
  if [[ -f "$KEY_FILE" ]]; then
    log "INFO" "Local private key exists: $KEY_FILE"
    chmod 400 "$KEY_FILE" 2>/dev/null || true
  else
    log "WARN" "Local private key missing: $KEY_FILE"
  fi
else
  log "INFO" "Creating new key pair: $KEY_NAME"
  
  # Create temp file first, then move to avoid permission issues
  temp_key=$(mktemp) || error_exit "Failed to create temp file"
  
  if ! aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" \
    --query 'KeyMaterial' --output text > "$temp_key" 2>&1; then
    rm -f "$temp_key"
    error_exit "Failed to create key pair"
  fi
  
  # Ensure keys directory exists and is writable
  if ! mkdir -p "$KEYS_DIR" 2>/dev/null; then
    rm -f "$temp_key"
    error_exit "Failed to create keys directory: $KEYS_DIR (may be permission issue with OneDrive)"
  fi
  
  # Move temp file to final location
  if ! mv "$temp_key" "$KEY_FILE" 2>/dev/null; then
    rm -f "$temp_key"
    error_exit "Failed to save key file (permission denied on $KEYS_DIR)"
  fi
  
  if ! chmod 400 "$KEY_FILE" 2>/dev/null; then
    log "WARN" "Could not set optimal permissions on key file (OneDrive limitation)"
  fi
  
  log "INFO" "Private key saved: $KEY_FILE"
fi

# Validate AMI exists
log "INFO" "Validating AMI: $AMI_ID"
if ! aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" &>/dev/null; then
  error_exit "AMI not found: $AMI_ID in region $REGION"
fi

# Launch EC2 instance
log "INFO" "Launching EC2 instance..."

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --region "$REGION" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$KEY_NAME-instance},{Key=Project,Value=AutomationLab},{Key=CreatedDate,Value=$(date -u +'%Y-%m-%d')}]" \
  --query 'Instances[0].InstanceId' \
  --output text 2>&1) || error_exit "Failed to launch instance"

log "INFO" "Instance launched: $INSTANCE_ID"

# Wait for instance to reach running state
log "INFO" "Waiting for instance to reach RUNNING state..."
if ! aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null; then
  error_exit "Instance failed to start within timeout"
fi

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text 2>/dev/null) || PUBLIC_IP="N/A"

log "INFO" "Instance running successfully"

echo ""
echo "============================================================"
echo "EC2 Instance Created Successfully"
echo "============================================================"
echo "Instance ID       : $INSTANCE_ID"
echo "Public IP         : $PUBLIC_IP"
echo "Instance Type     : $INSTANCE_TYPE"
echo "Region            : $REGION"
if [[ -f "$KEY_FILE" ]]; then
  echo "SSH Command       : ssh -i \"$KEY_FILE\" ec2-user@$PUBLIC_IP"
else
  echo "SSH Command       : Key file missing"
fi
echo "============================================================"
log "INFO" "EC2 setup completed. Instance: $INSTANCE_ID, IP: $PUBLIC_IP"

exit 0
