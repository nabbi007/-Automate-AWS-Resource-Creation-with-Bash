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

REGION="${AWS_REGION:-eu-west-1}"
TAG_KEY="${TAG_KEY:-Project}"
TAG_VALUE="${TAG_VALUE:-AutomationLab}"
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
  log "Searching for EC2 instances tagged $TAG_KEY=$TAG_VALUE..."
  local ids
  ids=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)

  if [[ -z "$ids" ]]; then
    log "No EC2 instances found with tag $TAG_KEY=$TAG_VALUE"
    return
  fi

  for id in $ids; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would terminate instance: $id"
      continue
    fi
    log "Terminating instance: $id"
    if aws ec2 terminate-instances --instance-ids "$id" --region "$REGION" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      log "Waiting for instance $id to terminate..."
      aws ec2 wait instance-terminated --instance-ids "$id" --region "$REGION" || warn "Timeout waiting for $id to terminate"
      success "Terminated instance: $id"
    else
      warn "Failed to terminate instance: $id"
      MANUAL_ACTIONS+=("Terminate instance $id via console or aws cli")
    fi
  done
}

delete_security_groups() {
  log "Searching for Security Groups tagged $TAG_KEY=$TAG_VALUE..."
  local sgs
  sgs=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true)

  if [[ -z "$sgs" ]]; then
    log "No Security Groups found with tag $TAG_KEY=$TAG_VALUE"
    return
  fi

  # Wait a short while for ENIs to be released
  sleep 5

  for sg in $sgs; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete Security Group: $sg"
      continue
    fi
    log "Deleting Security Group: $sg"
    if aws ec2 delete-security-group --group-id "$sg" --region "$REGION" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      success "Deleted Security Group: $sg"
    else
      warn "Failed to delete Security Group: $sg (may have dependencies)"
      MANUAL_ACTIONS+=("Delete or detach resources using Security Group $sg")
    fi
  done
}

empty_and_delete_bucket() {
  local bucket="$1"
  log "Processing bucket: $bucket"

  # Check object lock configuration
  local lockcfg
  lockcfg=$(aws s3api get-object-lock-configuration --bucket "$bucket" 2>/dev/null || true)
  if [[ -n "$lockcfg" ]] && echo "$lockcfg" | grep -q 'ObjectLockEnabled'; then
    warn "Bucket $bucket has Object Lock enabled and may prevent deletions"
    MANUAL_ACTIONS+=("Remove Object Lock or wait until retention expires for bucket $bucket")
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would suspend versioning and empty bucket: $bucket"
    return
  fi

  # Suspend versioning
  safe_run "aws s3api put-bucket-versioning --bucket '$bucket' --versioning-configuration Status=Suspended --region '$REGION'"

  # Delete public access block, bucket policy, lifecycle, replication, encryption
  safe_run "aws s3api delete-public-access-block --bucket '$bucket' --region '$REGION'"
  safe_run "aws s3api delete-bucket-policy --bucket '$bucket' --region '$REGION'"
  safe_run "aws s3api delete-bucket-lifecycle --bucket '$bucket' --region '$REGION'"
  safe_run "aws s3api delete-bucket-replication --bucket '$bucket' --region '$REGION'" || true
  safe_run "aws s3api delete-bucket-encryption --bucket '$bucket' --region '$REGION'" || true

  # Remove all object versions and delete markers (list in pages)
  log "Deleting object versions and delete markers for $bucket"
  while :; do
    versions=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output text 2>/dev/null || true)
    if [[ -z "$versions" ]]; then
      break
    fi

    # Extract pairs: Key VersionId from Versions
    aws s3api list-object-versions --bucket "$bucket" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key vid; do
      if [[ -n "$key" && -n "$vid" ]]; then
        aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" --region "$REGION" 2>/dev/null || true
      fi
    done || true

    aws s3api list-object-versions --bucket "$bucket" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key vid; do
      if [[ -n "$key" && -n "$vid" ]]; then
        aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" --region "$REGION" 2>/dev/null || true
      fi
    done || true

    # Also remove current objects
    aws s3 rm "s3://$bucket" --recursive --region "$REGION" 2>/dev/null || true

    # Check if there are still versions remaining; if not, break
    remaining=$(aws s3api list-object-versions --bucket "$bucket" --query 'length(Versions) + length(DeleteMarkers)' --output text 2>/dev/null || echo 0)
    if [[ "$remaining" == "0" || -z "$remaining" ]]; then
      break
    fi
  done

  # Final delete attempt
  if aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
    success "Deleted S3 bucket: $bucket"
    RESOURCES_DELETED=$((RESOURCES_DELETED+1))
  else
    warn "Could not delete bucket $bucket automatically"
    MANUAL_ACTIONS+=("Inspect and delete bucket $bucket via console (may have Object Lock or retention) - see $LOG_FILE")
  fi
}

delete_s3_buckets() {
  log "Searching for S3 buckets tagged $TAG_KEY=$TAG_VALUE..."
  local all_buckets
  all_buckets=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)
  local match=()

  for b in $all_buckets; do
    tags=$(aws s3api get-bucket-tagging --bucket "$b" --region "$REGION" 2>/dev/null || true)
    if echo "$tags" | grep -q "$TAG_VALUE" 2>/dev/null; then
      match+=("$b")
    fi
  done

  if [[ ${#match[@]} -eq 0 ]]; then
    log "No S3 buckets found with tag $TAG_KEY=$TAG_VALUE"
    return
  fi

  for bucket in "${match[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete S3 bucket: $bucket"
    else
      empty_and_delete_bucket "$bucket"
    fi
  done
}

delete_key_pairs() {
  log "Searching for EC2 key pairs..."
  local keys
  keys=$(aws ec2 describe-key-pairs --region "$REGION" --query 'KeyPairs[].KeyName' --output text 2>/dev/null || true)
  for k in $keys; do
    if [[ "$k" == *automation* ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would delete key pair: $k"
      else
        if aws ec2 delete-key-pair --key-name "$k" --region "$REGION" &>/dev/null; then
          success "Deleted Key Pair: $k"
          RESOURCES_DELETED=$((RESOURCES_DELETED+1))
        else
          warn "Failed to delete Key Pair: $k"
          MANUAL_ACTIONS+=("Delete key pair $k via console or aws cli")
        fi
      fi
    fi
  done
}

# Main
check_aws
log "Starting cleanup of AWS resources"
log "Region: $REGION, Tag: $TAG_KEY=$TAG_VALUE"

delete_ec2_instances
delete_security_groups
delete_s3_buckets
delete_key_pairs

# Summary
echo
echo "============================================================"
echo "Cleanup Summary"
echo "============================================================"
echo "Resources Deleted  : $RESOURCES_DELETED"
echo "Warnings Logged     : $RESOURCES_WARN"
echo "Region             : $REGION"
echo "Tag Filter         : $TAG_KEY=$TAG_VALUE"
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
