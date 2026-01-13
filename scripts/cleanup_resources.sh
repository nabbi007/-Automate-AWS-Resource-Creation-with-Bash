#!/bin/bash
# cleanup_resources.sh — Robust cleanup for AutomationLab resources
# - Uses JSON state manager for resource tracking
# - Terminates EC2 instances with tag validation
# - Deletes tagged Security Groups
# - Empties and deletes tagged S3 buckets (supports versioned buckets)
# - Deletes automation key pairs
# - Includes drift detection and remote backend sync

set -euo pipefail

# Allow re-running inside same shell where variables might be readonly: avoid 'readonly' redeclaration
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/../logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/automation.log}"
STATE_MANAGER="${SCRIPT_DIR}/state_manager.sh"

# Check if state file exists
if [[ ! -f "${SCRIPT_DIR}/../.aws-resources.state.json" ]]; then
  printf "%b" "${YELLOW}[ERROR] No state file found. Run creation scripts first or initialize: ./state_manager.sh init${NC}\n"
  exit 1
fi

# Check dependencies
if ! command -v jq &>/dev/null; then
  printf "%b" "${YELLOW}[ERROR] jq not found. Install: sudo apt install jq (or brew install jq)${NC}\n"
  exit 1
fi

REGION="${AWS_REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_DRIFT_CHECK="${SKIP_DRIFT_CHECK:-false}"

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
  
  # Sync from remote backend
  if [[ -n "${STATE_REMOTE_BACKEND:-}" ]]; then
    log "Syncing state from remote backend..."
    "$STATE_MANAGER" sync-pull 2>/dev/null || warn "Could not sync from remote backend"
  fi
  
  # Run drift detection (unless skipped)
  if [[ "$SKIP_DRIFT_CHECK" != "true" ]]; then
    log "Running drift detection..."
    if ! "$STATE_MANAGER" drift 2>/dev/null; then
      warn "Drift detected - some resources in state don't exist in AWS"
      log "Cleaning up non-existent resources from state..."
      "$STATE_MANAGER" clean 2>/dev/null || true
    fi
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
  log "Deleting EC2 instances from state..."
  
  # Get EC2 instances from state
  local instances
  instances=$("$STATE_MANAGER" get ec2_instances 2>/dev/null || echo "[]")
  
  local count
  count=$(echo "$instances" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$count" == "0" ]]; then
    log "No EC2 instances found in state (already clean)"
    return 0
  fi
  
  log "Found $count EC2 instance(s) in state"
  
  # Process each instance
  echo "$instances" | jq -c '.[]' | while read -r instance; do
    local id region state_name
    id=$(echo "$instance" | jq -r '.id')
    region=$(echo "$instance" | jq -r '.region // "'"$REGION"'"')
    state_name=$(echo "$instance" | jq -r '.name // "unknown"')
    
    # SAFETY CHECK: Verify resource has AutomationLab tag
    local has_tag
    has_tag=$(aws ec2 describe-instances --instance-ids "$id" --region "$region" \
      --query "Reservations[0].Instances[0].Tags[?Key=='Project' && Value=='AutomationLab']" --output text 2>/dev/null || echo "")
    
    if [[ -z "$has_tag" ]]; then
      warn "SAFETY: Instance $id does not have Project=AutomationLab tag. Skipping for safety."
      MANUAL_ACTIONS+=("Verify and manually delete instance $id if needed")
      continue
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would terminate instance: $id ($state_name)"
      continue
    fi
    
    # Check current state before attempting termination
    local aws_state
    aws_state=$(aws ec2 describe-instances --instance-ids "$id" --region "$region" \
      --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "not-found")
    
    if [[ "$aws_state" == "terminated" ]] || [[ "$aws_state" == "terminating" ]]; then
      log "Instance $id already terminated/terminating (idempotent: skipping)"
      "$STATE_MANAGER" remove ec2_instances "$id" 2>/dev/null || true
      continue
    fi
    
    if [[ "$aws_state" == "not-found" ]]; then
      log "Instance $id not found in AWS (removing from state)"
      "$STATE_MANAGER" remove ec2_instances "$id" 2>/dev/null || true
      continue
    fi
    
    log "Terminating instance: $id ($state_name, current state: $aws_state)"
    if aws ec2 terminate-instances --instance-ids "$id" --region "$region" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      log "Waiting for instance $id to terminate..."
      aws ec2 wait instance-terminated --instance-ids "$id" --region "$region" || warn "Timeout waiting for $id to terminate"
      success "Terminated instance: $id"
      "$STATE_MANAGER" remove ec2_instances "$id" 2>/dev/null || true
    else
      warn "Failed to terminate instance: $id"
      MANUAL_ACTIONS+=("Terminate instance $id via console or aws cli")
    fi
  done
}

delete_security_groups() {
  log "Deleting Security Groups from state..."
  
  # Get security groups from state
  local security_groups
  security_groups=$("$STATE_MANAGER" get security_groups 2>/dev/null || echo "[]")
  
  local count
  count=$(echo "$security_groups" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$count" == "0" ]]; then
    log "No Security Groups found in state (already clean)"
    return 0
  fi
  
  log "Found $count Security Group(s) in state"
  
  # Wait a short while for ENIs to be released
  sleep 5
  
  # Process each security group
  echo "$security_groups" | jq -c '.[]' | while read -r sg_obj; do
    local sg region sg_name
    sg=$(echo "$sg_obj" | jq -r '.id')
    region=$(echo "$sg_obj" | jq -r '.region // "'"$REGION"'"')
    sg_name=$(echo "$sg_obj" | jq -r '.name // "unknown"')
    
    # SAFETY CHECK: Verify resource has AutomationLab tag
    local has_tag
    has_tag=$(aws ec2 describe-security-groups --group-ids "$sg" --region "$region" \
      --query "SecurityGroups[0].Tags[?Key=='Project' && Value=='AutomationLab']" --output text 2>/dev/null || echo "")
    
    if [[ -z "$has_tag" ]]; then
      warn "SAFETY: Security Group $sg does not have Project=AutomationLab tag. Skipping for safety."
      MANUAL_ACTIONS+=("Verify and manually delete security group $sg if needed")
      continue
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete Security Group: $sg ($sg_name)"
      continue
    fi
    
    # Check if security group still exists
    if ! aws ec2 describe-security-groups --group-ids "$sg" --region "$region" &>/dev/null; then
      log "Security Group $sg already deleted (removing from state)"
      "$STATE_MANAGER" remove security_groups "$sg" 2>/dev/null || true
      continue
    fi
    
    log "Deleting Security Group: $sg ($sg_name)"
    if aws ec2 delete-security-group --group-id "$sg" --region "$region" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      success "Deleted Security Group: $sg"
      "$STATE_MANAGER" remove security_groups "$sg" 2>/dev/null || true
    else
      warn "Failed to delete Security Group: $sg (may have dependencies)"
      MANUAL_ACTIONS+=("Delete or detach resources using Security Group $sg")
    fi
  done
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
  log "Deleting S3 buckets from state..."
  
  # Get buckets from state
  local buckets
  buckets=$("$STATE_MANAGER" get s3_buckets 2>/dev/null || echo "[]")
  
  local count
  count=$(echo "$buckets" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$count" == "0" ]]; then
    log "No S3 buckets found in state (already clean)"
    return 0
  fi
  
  log "Found $count S3 bucket(s) in state"
  
  # Process each bucket
  echo "$buckets" | jq -c '.[]' | while read -r bucket_obj; do
    local bucket region
    bucket=$(echo "$bucket_obj" | jq -r '.name // .id')
    region=$(echo "$bucket_obj" | jq -r '.region // "'"$REGION"'"')
    
    # SAFETY CHECK: Verify resource has AutomationLab tag
    local has_tag
    has_tag=$(aws s3api get-bucket-tagging --bucket "$bucket" --region "$region" 2>/dev/null | grep -q "AutomationLab" && echo "yes" || echo "")
    
    if [[ -z "$has_tag" ]]; then
      warn "SAFETY: S3 bucket $bucket does not have Project=AutomationLab tag. Skipping for safety."
      MANUAL_ACTIONS+=("Verify and manually delete bucket $bucket if needed")
      continue
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete S3 bucket: $bucket"
    else
      empty_and_delete_bucket "$bucket" "$region"
      "$STATE_MANAGER" remove s3_buckets "$bucket" 2>/dev/null || true
    fi
  done
}

delete_key_pairs() {
  log "Deleting key pairs from state..."
  
  # Get key pairs from state
  local key_pairs
  key_pairs=$("$STATE_MANAGER" get key_pairs 2>/dev/null || echo "[]")
  
  local count
  count=$(echo "$key_pairs" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$count" == "0" ]]; then
    log "No key pairs found in state (already clean)"
    return 0
  fi
  
  log "Found $count key pair(s) in state"
  
  # Process each key pair
  echo "$key_pairs" | jq -c '.[]' | while read -r kp_obj; do
    local key_name region local_file
    key_name=$(echo "$kp_obj" | jq -r '.name // .id')
    region=$(echo "$kp_obj" | jq -r '.region // "'"$REGION"'"')
    local_file=$(echo "$kp_obj" | jq -r '.local_file // ""')
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would delete key pair: $key_name"
      continue
    fi
    
    # Check if key pair still exists
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" &>/dev/null; then
      log "Key pair $key_name already deleted (removing from state)"
      "$STATE_MANAGER" remove key_pairs "$key_name" 2>/dev/null || true
      continue
    fi
    
    log "Deleting key pair: $key_name"
    if aws ec2 delete-key-pair --key-name "$key_name" --region "$region" &>/dev/null; then
      RESOURCES_DELETED=$((RESOURCES_DELETED+1))
      success "Deleted key pair: $key_name"
      "$STATE_MANAGER" remove key_pairs "$key_name" 2>/dev/null || true
      
      # Also delete local key file if exists
      if [[ -n "$local_file" && -f "$local_file" ]]; then
        rm -f "$local_file" 2>/dev/null || true
        log "Deleted local key file: $local_file"
      fi
    else
      warn "Failed to delete key pair: $key_name"
      MANUAL_ACTIONS+=("Delete key pair $key_name via console or aws cli")
    fi
  done
}

# Main
check_aws
log "Starting cleanup of AWS resources from state"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN MODE] No resources will actually be deleted"
fi

delete_ec2_instances
delete_security_groups
delete_s3_buckets
delete_key_pairs

# Sync state to remote backend
if [[ "$DRY_RUN" != "true" ]] && [[ -n "${STATE_REMOTE_BACKEND:-}" ]]; then
  log "Syncing state to remote backend..."
  "$STATE_MANAGER" sync-push 2>/dev/null || warn "Could not sync to remote backend"
fi

# Summary
echo
echo "============================================================"
echo "Cleanup Summary"
echo "============================================================"
echo "Resources Deleted  : $RESOURCES_DELETED"
echo "Warnings Logged    : $RESOURCES_WARN"
echo "Region             : $REGION"
echo "State File         : ${SCRIPT_DIR}/../.aws-resources.state.json"
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
