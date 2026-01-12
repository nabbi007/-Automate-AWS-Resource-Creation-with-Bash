#!/bin/bash
# cleanup_resources.sh — Robust cleanup for AutomationLab resources
# - Terminates EC2 instances with tag
# - Deletes tagged Security Groups
# - Empties and deletes tagged S3 buckets (supports versioned buckets)
# - Deletes automation key pairs
# Professional output, safe retries, and clear manual-action hints

set -euo pipefail

# Allow re-running inside same shell where variables might be readonly: avoid 'readonly' redeclaration
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/../logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/automation.log}"

# Load AWS resource IDs from file
RESOURCES_FILE="${SCRIPT_DIR}/../.created_resources.txt"
if [[ ! -f "$RESOURCES_FILE" ]]; then
  printf "%b" "${YELLOW}[ERROR] No resources file found. Run creation scripts first.${NC}\n"
  printf "%b" "${YELLOW}Expected file: $RESOURCES_FILE${NC}\n"
  exit 1
fi

REGION="${AWS_REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"

RESOURCES_DELETED=0
RESOURCES_WARN=0
MANUAL_ACTIONS=()

# colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize logging
mkdir -p "$LOG_DIR" || { printf "%b" "${YELLOW}[WARN] Cannot create log directory: $LOG_DIR${NC}\n"; }
touch "$LOG_FILE" || { printf "%b" "${YELLOW}[WARN] Cannot create log file: $LOG_FILE${NC}\n"; }

log() { printf "%b" "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${NC}\n" | tee -a "$LOG_FILE"; }
success() { printf "%b" "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1${NC}\n" | tee -a "$LOG_FILE"; }
warn() { printf "%b" "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1${NC}\n" | tee -a "$LOG_FILE"; RESOURCES_WARN=$((RESOURCES_WARN+1)); }
error_log() { printf "%b" "[ERROR] $1\n" | tee -a "$LOG_FILE"; }

check_aws() {
  if ! command -v aws &>/dev/null; then
    printf "%b" "${YELLOW}[ERROR] AWS CLI not found. Install and configure credentials.${NC}\n"
    exit 1
  fi
  if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
    printf "%b" "${YELLOW}[ERROR] AWS credentials invalid for region $REGION${NC}\n"
    exit 1
  fi
}

safe_run() { # run command, log on failure but continue
  if ! eval "$1"; then
    warn "Command failed: $1"
    return 1
  fi
  return 0
}

delete_ec2_instances() {
  log "Deleting EC2 instances from resources file..."
  
  # Read EC2 instance IDs from resources file
  local instances
  instances=$(grep "^EC2_INSTANCE:" "$RESOURCES_FILE" 2>/dev/null || true)
  
  if [[ -z "$instances" ]]; then
    log "No EC2 instances found in resources file (already clean)"
    return 0
  fi
  
  while IFS=: read -r type id region; do
    [[ "$type" != "EC2_INSTANCE" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would terminate instance: $id"
      continue
    fi
    
    # Check current state before attempting termination
    local state
    state=$(aws ec2 describe-instances --instance-ids "$id" --region "${region:-$REGION}" \
      --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "unknown")
    
    if [[ "$state" == "terminated" ]] || [[ "$state" == "terminating" ]]; then
      log "Instance $id already terminated/terminating (idempotent: skipping)"
      continue
    fi
    
    log "Terminating instance: $id (current state: $state)"
    if aws ec2 terminate-instances --instance-ids "$id" --region "${region:-$REGION}" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      log "Waiting for instance $id to terminate..."
      aws ec2 wait instance-terminated --instance-ids "$id" --region "${region:-$REGION}" || warn "Timeout waiting for $id to terminate"
      success "Terminated instance: $id"
    else
      warn "Failed to terminate instance: $id"
      MANUAL_ACTIONS+=("Terminate instance $id via console or aws cli")
    fi
  done < <(echo "$instances")
}

delete_security_groups() {
  log "Deleting Security Groups from resources file..."
  
  # Read security group IDs from resources file
  local security_groups
  security_groups=$(grep "^SECURITY_GROUP:" "$RESOURCES_FILE" 2>/dev/null || true)
  
  if [[ -z "$security_groups" ]]; then
    log "No Security Groups found in resources file (already clean)"
    return 0
  fi
  
  # Wait a short while for ENIs to be released
  sleep 5
  
  while IFS=: read -r type sg region; do
    [[ "$type" != "SECURITY_GROUP" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete Security Group: $sg"
      continue
    fi
    
    # Check if security group still exists
    if ! aws ec2 describe-security-groups --group-ids "$sg" --region "${region:-$REGION}" &>/dev/null; then
      log "Security Group $sg already deleted (idempotent: skipping)"
      continue
    fi
    
    log "Deleting Security Group: $sg"
    if aws ec2 delete-security-group --group-id "$sg" --region "${region:-$REGION}" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      success "Deleted Security Group: $sg"
    else
      warn "Failed to delete Security Group: $sg (may have dependencies)"
      MANUAL_ACTIONS+=("Delete or detach resources using Security Group $sg")
    fi
  done < <(echo "$security_groups")
}

empty_and_delete_bucket() {
  local bucket="$1"
  local bucket_region="${2:-$REGION}"
  log "Processing bucket: $bucket (region: $bucket_region)"

  # Check object lock configuration
  local lockcfg
  lockcfg=$(aws s3api get-object-lock-configuration --bucket "$bucket" --region "$bucket_region" 2>/dev/null || true)
  if [[ -n "$lockcfg" ]] && echo "$lockcfg" | grep -q 'ObjectLockEnabled'; then
    warn "Bucket $bucket has Object Lock enabled and may prevent deletions"
    MANUAL_ACTIONS+=("Remove Object Lock or wait until retention expires for bucket $bucket")
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would suspend versioning and empty bucket: $bucket"
    return
  fi

  # Suspend versioning
  safe_run "aws s3api put-bucket-versioning --bucket '$bucket' --versioning-configuration Status=Suspended --region '$bucket_region'"

  # Delete public access block, bucket policy, lifecycle, replication, encryption
  safe_run "aws s3api delete-public-access-block --bucket '$bucket' --region '$bucket_region'"
  safe_run "aws s3api delete-bucket-policy --bucket '$bucket' --region '$bucket_region'"
  safe_run "aws s3api delete-bucket-lifecycle --bucket '$bucket' --region '$bucket_region'"
  safe_run "aws s3api delete-bucket-replication --bucket '$bucket' --region '$bucket_region'" || true
  safe_run "aws s3api delete-bucket-encryption --bucket '$bucket' --region '$bucket_region'" || true

  # Remove all object versions and delete markers (list in pages)
  log "Deleting object versions and delete markers for $bucket"
  while :; do
    versions=$(aws s3api list-object-versions --bucket "$bucket" --region "$bucket_region" --max-items 1000 --output text 2>/dev/null || true)
    if [[ -z "$versions" ]]; then
      break
    fi

    # Extract pairs: Key VersionId from Versions
    aws s3api list-object-versions --bucket "$bucket" --region "$bucket_region" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key vid; do
      if [[ -n "$key" && -n "$vid" ]]; then
        aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" --region "$bucket_region" 2>/dev/null || true
      fi
    done || true

    aws s3api list-object-versions --bucket "$bucket" --region "$bucket_region" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key vid; do
      if [[ -n "$key" && -n "$vid" ]]; then
        aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" --region "$bucket_region" 2>/dev/null || true
      fi
    done || true

    # Also remove current objects
    aws s3 rm "s3://$bucket" --recursive --region "$bucket_region" 2>/dev/null || true

    # Check if there are still versions remaining; if not, break
    remaining=$(aws s3api list-object-versions --bucket "$bucket" --region "$bucket_region" --query 'length(Versions) + length(DeleteMarkers)' --output text 2>/dev/null || echo 0)
    if [[ "$remaining" == "0" || -z "$remaining" ]]; then
      break
    fi
  done

  # Check if bucket still exists before final delete attempt
  if ! aws s3api head-bucket --bucket "$bucket" --region "$bucket_region" 2>/dev/null; then
    log "Bucket $bucket already deleted (idempotent: skipping final delete)"
    return 0
  fi
  
  # Final delete attempt
  if aws s3api delete-bucket --bucket "$bucket" --region "$bucket_region" 2>/dev/null; then
    success "Deleted S3 bucket: $bucket"
    RESOURCES_DELETED=$((RESOURCES_DELETED+1))
  else
    warn "Could not delete bucket $bucket automatically"
    MANUAL_ACTIONS+=("Inspect and delete bucket $bucket via console (may have Object Lock or retention) - see $LOG_FILE")
  fi
}

delete_s3_buckets() {
  log "Deleting S3 buckets from resources file..."
  
  # Read bucket names from resources file
  local buckets
  buckets=$(grep "^S3_BUCKET:" "$RESOURCES_FILE" 2>/dev/null || true)
  
  if [[ -z "$buckets" ]]; then
    log "No S3 buckets found in resources file (already clean)"
    return 0
  fi
  
  while IFS=: read -r type bucket region; do
    [[ "$type" != "S3_BUCKET" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete S3 bucket: $bucket"
    else
      empty_and_delete_bucket "$bucket" "${region:-$REGION}"
    fi
  done < <(echo "$buckets")
}

delete_key_pairs() {
  log "Deleting key pairs from resources file..."
  
  # Read key pair names from resources file
  local key_pairs
  key_pairs=$(grep "^KEY_PAIR:" "$RESOURCES_FILE" 2>/dev/null || true)
  
  if [[ -z "$key_pairs" ]]; then
    log "No key pairs found in resources file (already clean)"
    return 0
  fi
  
  while IFS=: read -r type key_name region; do
    [[ "$type" != "KEY_PAIR" ]] && continue
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete key pair: $key_name"
      continue
    fi
    
    # Check if key pair still exists
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "${region:-$REGION}" &>/dev/null; then
      log "Key pair $key_name already deleted"
      continue
    fi
    
    log "Deleting key pair: $key_name"
    if aws ec2 delete-key-pair --key-name "$key_name" --region "${region:-$REGION}" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      success "Deleted key pair: $key_name"
      
      # Also delete local key file if exists
      local key_file="${SCRIPT_DIR}/../keys/${key_name}.pem"
      if [[ -f "$key_file" ]]; then
        rm -f "$key_file" 2>/dev/null || true
        log "INFO" "Deleted local key file: $key_file"
      fi
    else
      warn "Failed to delete key pair: $key_name"
      MANUAL_ACTIONS+=("Delete key pair $key_name via console or aws cli")
    fi
  done < <(echo "$key_pairs")
}

# Main
check_aws
log "Starting cleanup of AWS resources"
log "Resources File: $RESOURCES_FILE"

delete_ec2_instances
delete_security_groups
delete_s3_buckets
delete_key_pairs

# Remove resources file after successful cleanup
if [[ "$DRY_RUN" != "true" ]] && [[ -f "$RESOURCES_FILE" ]]; then
  rm -f "$RESOURCES_FILE"
  log "Resources file removed after cleanup"
fi

# Summary
echo
echo "============================================================"
echo "Cleanup Summary"
echo "============================================================"
echo "Resources Deleted  : $RESOURCES_DELETED"
echo "Warnings Logged    : $RESOURCES_WARN"
echo "Region             : $REGION"
echo "Resources File     : $RESOURCES_FILE"
echo "Log File           : $LOG_FILE"
echo "============================================================"

if [[ ${#MANUAL_ACTIONS[@]} -gt 0 ]]; then
  printf "%b" "${YELLOW}[WARN] Some resources require manual actions:${NC}\n"
  for a in "${MANUAL_ACTIONS[@]}"; do
    echo " - $a"
  done
  printf "%b" "${BLUE}See detailed logs in: $LOG_FILE${NC}\n"
else
  printf "%b" "${GREEN}[SUCCESS] All deletable resources cleaned up.${NC}\n"
fi

exit 0
