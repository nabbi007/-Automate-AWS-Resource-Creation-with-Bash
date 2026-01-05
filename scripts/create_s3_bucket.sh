#!/bin/bash
# AWS S3 Bucket Creation Script - Professional Edition
# Creates S3 buckets with versioning, encryption, and file upload

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
readonly LOG_FILE="${LOG_DIR}/automation.log"
readonly ASSETS_DIR="${SCRIPT_DIR}/../assets"

REGION="${AWS_REGION:-eu-west-1}"
BUCKET_NAME="${BUCKET_NAME:-automation-lab-$(date +%s)}"
SAMPLE_FILE="${ASSETS_DIR}/welcome.txt"
BUCKET_ID=""

# Initialize logging
mkdir -p "$LOG_DIR" || { echo "ERROR: Cannot create log directory" >&2; exit 1; }
touch "$LOG_FILE" || { echo "ERROR: Cannot create log file" >&2; exit 1; }

log() {
  local level="$1" msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR" "$1"
  if [[ -n "$BUCKET_ID" ]]; then
    log "WARN" "Cleaning up S3 bucket: $BUCKET_ID"
    aws s3 rm "s3://$BUCKET_ID" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$BUCKET_ID" --region "$REGION" 2>/dev/null || true
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

log "INFO" "Starting S3 bucket creation process"
log "INFO" "Region: $REGION, Bucket: $BUCKET_NAME"

# Validate bucket name format (AWS S3 naming rules)
if ! [[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || [[ ${#BUCKET_NAME} -lt 3 ]] || [[ ${#BUCKET_NAME} -gt 63 ]]; then
  error_exit "Invalid bucket name: $BUCKET_NAME (3-63 chars, lowercase, numbers, hyphens, dots)"
fi

# Check if bucket already exists
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
  log "WARN" "S3 bucket '$BUCKET_NAME' already exists"
  BUCKET_ID="$BUCKET_NAME"
else
  log "INFO" "Creating S3 bucket: $BUCKET_NAME"
  
  # Create bucket with proper region handling
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>&1 || \
      error_exit "Failed to create bucket"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" 2>&1 || \
      error_exit "Failed to create bucket"
  fi
  
  BUCKET_ID="$BUCKET_NAME"
  log "INFO" "Bucket created: $BUCKET_NAME"
  
  # Tag the bucket
  aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" \
    --tagging 'TagSet=[{Key=Name,Value='"$BUCKET_NAME"'},{Key=Project,Value=AutomationLab},{Key=CreatedDate,Value='"$(date -u +'%Y-%m-%d')"'}]' 2>&1 || \
    error_exit "Failed to tag bucket"
  
  log "INFO" "Bucket tagged successfully"
fi

# Enable versioning
log "INFO" "Enabling versioning..."
aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --region "$REGION" \
  --versioning-configuration Status=Enabled 2>&1 || \
  error_exit "Failed to enable versioning"

log "INFO" "Versioning enabled successfully"

# Enable server-side encryption
log "INFO" "Enabling encryption..."
aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$REGION" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }' 2>&1 || error_exit "Failed to enable encryption"

log "INFO" "Encryption enabled successfully"

# Block public access
log "INFO" "Blocking public access..."
aws s3api put-public-access-block --bucket "$BUCKET_NAME" --region "$REGION" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>&1 || \
  error_exit "Failed to block public access"

log "INFO" "Public access blocked"

# Upload sample file if exists
if [[ -f "$SAMPLE_FILE" ]]; then
  log "INFO" "Uploading sample file: $SAMPLE_FILE"
  aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/welcome.txt" --region "$REGION" 2>&1 || \
    error_exit "Failed to upload sample file"
  log "INFO" "Sample file uploaded successfully"
else
  log "WARN" "Sample file not found: $SAMPLE_FILE"
fi

log "INFO" "S3 bucket setup completed successfully"

echo ""
echo "============================================================"
echo "S3 Bucket Created Successfully"
echo "============================================================"
echo "Bucket Name       : $BUCKET_NAME"
echo "Region            : $REGION"
echo "Versioning        : Enabled"
echo "Encryption        : AES256"
echo "Public Access     : Blocked"
echo "Log File          : $LOG_FILE"
echo "============================================================"

exit 0
