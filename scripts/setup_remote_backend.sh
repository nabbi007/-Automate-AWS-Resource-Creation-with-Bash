#!/bin/bash
# Setup Remote Backend - Create S3 bucket for state storage
# This bucket will store the JSON state files with versioning enabled

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
readonly LOG_FILE="${LOG_DIR}/automation.log"

REGION="${AWS_REGION:-eu-west-1}"
BACKEND_BUCKET="${STATE_REMOTE_BACKEND:-aws-automation-state-$(date +%s)}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize logging
mkdir -p "$LOG_DIR" || { echo "ERROR: Cannot create log directory" >&2; exit 1; }
touch "$LOG_FILE" || { echo "ERROR: Cannot create log file" >&2; exit 1; }

log() {
  local level="$1" msg="$2"
  echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg${NC}" | tee -a "$LOG_FILE"
}

success() {
  local msg="$1"
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $msg${NC}" | tee -a "$LOG_FILE"
}

error_exit() {
  echo -e "${YELLOW}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
  exit 1
}

# Validate prerequisites
if ! command -v aws &>/dev/null; then
  error_exit "AWS CLI is not installed"
fi

if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
  error_exit "AWS credentials not configured or invalid for region: $REGION"
fi

log "INFO" "Setting up remote backend S3 bucket"
log "INFO" "Bucket name: $BACKEND_BUCKET"
log "INFO" "Region: $REGION"

# Check if bucket already exists
if aws s3api head-bucket --bucket "$BACKEND_BUCKET" --region "$REGION" 2>/dev/null; then
  log "INFO" "Bucket '$BACKEND_BUCKET' already exists. Verifying configuration..."
  
  # Check versioning
  versioning=$(aws s3api get-bucket-versioning --bucket "$BACKEND_BUCKET" --region "$REGION" --query 'Status' --output text 2>/dev/null || echo "None")
  if [[ "$versioning" != "Enabled" ]]; then
    log "INFO" "Enabling versioning..."
    aws s3api put-bucket-versioning --bucket "$BACKEND_BUCKET" --region "$REGION" \
      --versioning-configuration Status=Enabled 2>&1 || error_exit "Failed to enable versioning"
    success "Versioning enabled"
  else
    log "INFO" "Versioning already enabled"
  fi
  
  # Check encryption
  if ! aws s3api get-bucket-encryption --bucket "$BACKEND_BUCKET" --region "$REGION" &>/dev/null; then
    log "INFO" "Enabling encryption..."
    aws s3api put-bucket-encryption --bucket "$BACKEND_BUCKET" --region "$REGION" \
      --server-side-encryption-configuration '{
        "Rules": [{
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256"
          },
          "BucketKeyEnabled": true
        }]
      }' 2>&1 || error_exit "Failed to enable encryption"
    success "Encryption enabled"
  else
    log "INFO" "Encryption already enabled"
  fi
else
  log "INFO" "Creating S3 bucket: $BACKEND_BUCKET"
  
  # Create bucket with proper region handling
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BACKEND_BUCKET" --region "$REGION" 2>&1 || \
      error_exit "Failed to create bucket"
  else
    aws s3api create-bucket --bucket "$BACKEND_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" 2>&1 || \
      error_exit "Failed to create bucket"
  fi
  
  success "Bucket created: $BACKEND_BUCKET"
  
  # Tag the bucket
  log "INFO" "Tagging bucket..."
  aws s3api put-bucket-tagging --bucket "$BACKEND_BUCKET" --region "$REGION" \
    --tagging 'TagSet=[{Key=Name,Value='"$BACKEND_BUCKET"'},{Key=Project,Value=AutomationLab},{Key=Purpose,Value=StateBackend}]' 2>&1 || \
    error_exit "Failed to tag bucket"
  
  success "Bucket tagged successfully"
  
  # Enable versioning
  log "INFO" "Enabling versioning..."
  aws s3api put-bucket-versioning --bucket "$BACKEND_BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled 2>&1 || \
    error_exit "Failed to enable versioning"
  
  success "Versioning enabled"
  
  # Enable server-side encryption
  log "INFO" "Enabling encryption..."
  aws s3api put-bucket-encryption --bucket "$BACKEND_BUCKET" --region "$REGION" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }' 2>&1 || error_exit "Failed to enable encryption"
  
  success "Encryption enabled"
  
  # Block public access
  log "INFO" "Blocking public access..."
  aws s3api put-public-access-block --bucket "$BACKEND_BUCKET" --region "$REGION" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>&1 || \
    error_exit "Failed to block public access"
  
  success "Public access blocked"
fi

# Display bucket configuration
log "INFO" "Fetching bucket configuration..."
versioning_status=$(aws s3api get-bucket-versioning --bucket "$BACKEND_BUCKET" --region "$REGION" --query 'Status' --output text 2>/dev/null || echo "Disabled")
encryption_algo=$(aws s3api get-bucket-encryption --bucket "$BACKEND_BUCKET" --region "$REGION" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo "None")

echo ""
echo "============================================================"
echo "Remote Backend S3 Bucket Ready"
echo "============================================================"
echo "Bucket Name       : $BACKEND_BUCKET"
echo "Region            : $REGION"
echo "Versioning        : $versioning_status"
echo "Encryption        : $encryption_algo"
echo "Public Access     : Blocked"
echo "============================================================"
echo ""
echo "To use this backend, set the environment variable:"
echo "  export STATE_REMOTE_BACKEND=$BACKEND_BUCKET"
echo ""
echo "Add to ~/.bashrc for persistence:"
echo "  echo 'export STATE_REMOTE_BACKEND=$BACKEND_BUCKET' >> ~/.bashrc"
echo ""
echo "Then run: source ~/.bashrc"
echo "============================================================"

success "Remote backend setup complete!"

exit 0
