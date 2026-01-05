#!/bin/bash
# -------------------------------------------------------------
# Script Name : create_s3_bucket.sh
# Purpose     : Create S3 bucket with versioning and upload file
# Author      : Iliasu Abubakar
# -------------------------------------------------------------

set -euo pipefail

# ---------------------- CONFIGURATION -------------------------
LOG_FILE="../logs/automation.log"
REGION="us-east-1"
BUCKET_NAME="automation-lab-$(date +%s)"
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

log "Creating S3 bucket: $BUCKET_NAME"

# Create bucket
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION"

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# Upload sample file
aws s3 cp ../assets/welcome.txt s3://"$BUCKET_NAME"/welcome.txt

log "S3 bucket created and file uploaded"
log "Bucket Name: $BUCKET_NAME"
