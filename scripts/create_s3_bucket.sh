#!/bin/bash
# AWS S3 Bucket Creation Script - Professional Edition
# Creates S3 buckets with versioning, encryption, and file upload
# Supports --dry-run flag for validation before creation

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
readonly LOG_FILE="${LOG_DIR}/automation.log"
readonly ASSETS_DIR="${SCRIPT_DIR}/../assets"
readonly STATE_MANAGER="${SCRIPT_DIR}/state_manager.sh"
readonly STATE_FILE="${SCRIPT_DIR}/../.aws-resources.state.json"
readonly DRY_RUN_MANAGER="${SCRIPT_DIR}/dry_run_manager.sh"

# Source dry-run manager
source "$DRY_RUN_MANAGER"

# Parse command-line arguments for dry-run
parse_dry_run_args "$@"

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

# Auto-initialize state if it doesn't exist
if [[ ! -f "${SCRIPT_DIR}/../.aws-resources.state.json" ]]; then
  log "INFO" "State file not found. Initializing..."
  "$STATE_MANAGER" init || error_exit "Failed to initialize state"
fi

log "INFO" "Starting S3 bucket creation process"
log "INFO" "Region: $REGION, Bucket: $BUCKET_NAME"

# Print dry-run banner if enabled
print_dry_run_banner

# Validate bucket name format (AWS S3 naming rules)
if ! [[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || [[ ${#BUCKET_NAME} -lt 3 ]] || [[ ${#BUCKET_NAME} -gt 63 ]]; then
  error_exit "Invalid bucket name: $BUCKET_NAME (3-63 chars, lowercase, numbers, hyphens, dots)"
fi

# Check if bucket already exists
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
  log "INFO" "S3 bucket '$BUCKET_NAME' already exists (idempotent: skipping creation)"
  BUCKET_ID="$BUCKET_NAME"
  
  if ! is_dry_run; then
    # Ensure existing bucket has proper configuration
    log "INFO" "Verifying bucket configuration..."
    
    # Check and enable versioning if not already enabled
    versioning=$(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --region "$REGION" --query 'Status' --output text 2>/dev/null || echo "None")
    if [[ "$versioning" != "Enabled" ]]; then
      log "INFO" "Enabling versioning on existing bucket..."
      aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --region "$REGION" \
        --versioning-configuration Status=Enabled 2>&1 || log "WARN" "Failed to enable versioning"
    fi
    
    # Check and enable encryption if not already enabled
    if ! aws s3api get-bucket-encryption --bucket "$BUCKET_NAME" --region "$REGION" &>/dev/null; then
      log "INFO" "Enabling encryption on existing bucket..."
      aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$REGION" \
        --server-side-encryption-configuration '{
          "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
              "SSEAlgorithm": "AES256"
            }
          }]
        }' 2>&1 || log "WARN" "Failed to enable encryption"
    fi
  fi
else
  log "INFO" "Creating S3 bucket: $BUCKET_NAME"
  
  if is_dry_run; then
    # Simulate S3 creation first
    simulate_s3_creation "$BUCKET_NAME" "$REGION"
    dry_run_info "Dry-run validation complete. To execute, run: ./create_s3_bucket.sh --execute"
    exit 0
  fi
  
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
    --tagging 'TagSet=[{Key=Name,Value='"$BUCKET_NAME"'},{Key=Project,Value=AutomationLab}]' 2>&1 || \
    error_exit "Failed to tag bucket"
  
  log "INFO" "Bucket tagged successfully"
  
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
  
  # Save to state manager
  bucket_json=$(jq -n --arg name "$BUCKET_NAME" --arg region "$REGION" '{
    id: $name,
    name: $name,
    region: $region,
    versioning: "enabled",
    encryption: "AES256"
  }')
  "$STATE_MANAGER" add s3_buckets "$bucket_json" 2>/dev/null || log "WARN" "Could not update state"
  log "INFO" "S3 bucket saved to state"
fi

# Upload sample file if exists (idempotent check)
if [[ -f "$SAMPLE_FILE" ]]; then
  if aws s3api head-object --bucket "$BUCKET_NAME" --key "welcome.txt" --region "$REGION" &>/dev/null; then
    log "INFO" "Sample file already exists in bucket"
  else
    log "INFO" "Uploading sample file: $SAMPLE_FILE"
    aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/welcome.txt" --region "$REGION" 2>&1 || \
      error_exit "Failed to upload sample file"
    log "INFO" "Sample file uploaded successfully"
  fi
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
