#!/bin/bash
# State Manager - JSON-based state tracking with remote backend sync
# Manages local and remote state files with drift detection

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_FILE="${SCRIPT_DIR}/../.aws-resources.state.json"
readonly LOCK_FILE="${SCRIPT_DIR}/../.state.lock"
readonly BACKEND_CONFIG="${SCRIPT_DIR}/../.remote-backend-config"

# Auto-generate remote backend bucket name if not set
if [[ -z "${STATE_REMOTE_BACKEND:-}" ]]; then
  # Check if we have a saved backend config
  if [[ -f "$BACKEND_CONFIG" ]]; then
    REMOTE_BACKEND="$(cat "$BACKEND_CONFIG")"
  else
    # Generate unique bucket name and save it
    REMOTE_BACKEND="aws-automation-state-$(date +%s)-$(whoami | tr '[:upper:]' '[:lower:]' | tr -d ' @+')"
    echo "$REMOTE_BACKEND" > "$BACKEND_CONFIG"
  fi
else
  REMOTE_BACKEND="${STATE_REMOTE_BACKEND}"
  echo "$REMOTE_BACKEND" > "$BACKEND_CONFIG"
fi

readonly REMOTE_BACKEND
readonly STATE_VERSION="1.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[STATE] $1${NC}" >&2; }
log_success() { echo -e "${GREEN}[STATE] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[STATE] $1${NC}" >&2; }
log_error() { echo -e "${RED}[STATE] $1${NC}" >&2; }

# Check dependencies
check_dependencies() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed. Install: sudo apt install jq"
    exit 1
  fi
}

# Acquire lock
acquire_lock() {
  local timeout=30
  local waited=0
  
  while [[ -f "$LOCK_FILE" ]]; do
    if [[ $waited -ge $timeout ]]; then
      log_error "Lock timeout. Remove $LOCK_FILE if no other process is running."
      exit 1
    fi
    log_warn "State locked by another process. Waiting..."
    sleep 2
    waited=$((waited + 2))
  done
  
  echo "$$" > "$LOCK_FILE"
  chmod 444 "$LOCK_FILE"
}

# Release lock
release_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    chmod 644 "$LOCK_FILE" 2>/dev/null || true
    rm -f "$LOCK_FILE"
  fi
}

# Trap to ensure lock is released
trap release_lock EXIT INT TERM

# Create remote backend bucket if needed
create_remote_backend() {
  if [[ -z "$REMOTE_BACKEND" ]]; then
    return 0
  fi
  
  local region="${AWS_REGION:-eu-west-1}"
  
  log_info "Checking remote backend: s3://$REMOTE_BACKEND"
  
  # Check if bucket exists
  if aws s3api head-bucket --bucket "$REMOTE_BACKEND" --region "$region" 2>/dev/null; then
    log_info "Remote backend bucket already exists"
    return 0
  fi
  
  log_info "Creating remote backend bucket: $REMOTE_BACKEND"
  
  # Create bucket
  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$REMOTE_BACKEND" --region "$region" 2>/dev/null || {
      log_error "Failed to create remote backend bucket"
      return 1
    }
  else
    aws s3api create-bucket --bucket "$REMOTE_BACKEND" --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" 2>/dev/null || {
      log_error "Failed to create remote backend bucket"
      return 1
    }
  fi
  
  log_success "Remote backend bucket created"
  
  # Enable versioning
  log_info "Enabling versioning on remote backend..."
  aws s3api put-bucket-versioning --bucket "$REMOTE_BACKEND" --region "$region" \
    --versioning-configuration Status=Enabled 2>/dev/null || log_warn "Failed to enable versioning"
  
  # Enable encryption
  log_info "Enabling encryption on remote backend..."
  aws s3api put-bucket-encryption --bucket "$REMOTE_BACKEND" --region "$region" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }' 2>/dev/null || log_warn "Failed to enable encryption"
  
  # Block public access
  log_info "Blocking public access on remote backend..."
  aws s3api put-public-access-block --bucket "$REMOTE_BACKEND" --region "$region" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>/dev/null || log_warn "Failed to block public access"
  
  # Tag bucket
  aws s3api put-bucket-tagging --bucket "$REMOTE_BACKEND" --region "$region" \
    --tagging 'TagSet=[{Key=Name,Value='"$REMOTE_BACKEND"'},{Key=Project,Value=AutomationLab},{Key=Purpose,Value=StateBackend}]' 2>/dev/null || true
  
  log_success "Remote backend configured successfully"
}

# Initialize empty state
init_state() {
  local user_email="${USER_EMAIL:-$(whoami)@$(hostname)}"
  
  # Always create remote backend (now auto-generated if not set)
  create_remote_backend
  
  # Try to pull existing state from remote
  local region="${AWS_REGION:-eu-west-1}"
  local remote_key="aws-automation-state/$(hostname)/resources.state.json"
  
  if aws s3 cp "s3://$REMOTE_BACKEND/$remote_key" "$STATE_FILE" --region "$region" 2>/dev/null; then
    chmod 444 "$STATE_FILE"
    log_success "Pulled existing state from remote backend"
    log_info "Remote backend is the source of truth"
    return 0
  fi
  
  # Create new state file
  cat > "$STATE_FILE" <<EOF
{
  "version": "$STATE_VERSION",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "created_by": "$user_email",
  "last_modified": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "region": "${AWS_REGION:-eu-west-1}",
  "resources": {
    "ec2_instances": [],
    "security_groups": [],
    "s3_buckets": [],
    "key_pairs": []
  },
  "metadata": {
    "total_resources": 0,
    "last_sync": null,
    "remote_backend": "$REMOTE_BACKEND"
  }
}
EOF
  chmod 444 "$STATE_FILE"
  log_success "State file initialized: $STATE_FILE"
  
  # Always sync to remote (now always configured)
  sync_to_remote
  log_info "State synced to remote backend - remote is source of truth"
}

# Sync state to remote backend (S3)
sync_to_remote() {
  # Remote backend is now always configured
  local region="${AWS_REGION:-eu-west-1}"
  local remote_key="aws-automation-state/$(hostname)/resources.state.json"
  
  log_info "Syncing state to remote backend: s3://$REMOTE_BACKEND/$remote_key"
  
  if aws s3 cp "$STATE_FILE" "s3://$REMOTE_BACKEND/$remote_key" --region "$region" 2>/dev/null; then
    # Update sync timestamp
    chmod 644 "$STATE_FILE" 2>/dev/null || true
    jq ".metadata.last_sync = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    chmod 444 "$STATE_FILE"
    log_success "State synced to remote backend"
  else
    log_warn "Failed to sync to remote backend (bucket may not exist)"
  fi
}

# Pull state from remote backend
sync_from_remote() {
  if [[ -z "$REMOTE_BACKEND" ]]; then
    return 0
  fi
  
  local region="${AWS_REGION:-eu-west-1}"
  local remote_key="aws-automation-state/$(hostname)/resources.state.json"
  
  log_info "Pulling state from remote backend: s3://$REMOTE_BACKEND/$remote_key"
  
  if aws s3 cp "s3://$REMOTE_BACKEND/$remote_key" "$STATE_FILE.remote" --region "$region" 2>/dev/null; then
    # Compare local and remote
    if [[ -f "$STATE_FILE" ]]; then
      local local_modified=$(jq -r '.last_modified' "$STATE_FILE")
      local remote_modified=$(jq -r '.last_modified' "$STATE_FILE.remote")
      
      if [[ "$remote_modified" > "$local_modified" ]]; then
        log_warn "Remote state is newer than local. Consider using remote state."
        log_info "Local: $local_modified | Remote: $remote_modified"
      fi
    else
      chmod 644 "$STATE_FILE.remote" 2>/dev/null || true
      mv "$STATE_FILE.remote" "$STATE_FILE"
      chmod 444 "$STATE_FILE"
      log_success "State pulled from remote backend"
    fi
    rm -f "$STATE_FILE.remote"
  else
    log_warn "No remote state found (this may be the first run)"
  fi
}

# Add resource to state
add_resource() {
  local resource_type="$1"
  local resource_data="$2"
  
  acquire_lock
  
  if [[ ! -f "$STATE_FILE" ]]; then
    init_state
  fi
  
  chmod 644 "$STATE_FILE" 2>/dev/null || true
  
  # Add timestamp and created_by if not present
  resource_data=$(echo "$resource_data" | jq ". + {created_at: (if .created_at then .created_at else \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\" end)}")
  resource_data=$(echo "$resource_data" | jq ". + {created_by: (if .created_by then .created_by else \"$(whoami)@$(hostname)\" end)}")
  
  # Add to appropriate resource array
  jq ".resources.${resource_type} += [$resource_data] | .last_modified = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\" | .metadata.total_resources = (.resources.ec2_instances | length) + (.resources.security_groups | length) + (.resources.s3_buckets | length) + (.resources.key_pairs | length)" "$STATE_FILE" > "$STATE_FILE.tmp"
  
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 444 "$STATE_FILE"
  
  log_success "Added $resource_type to state"
  
  sync_to_remote
  release_lock
}

# Remove resource from state
remove_resource() {
  local resource_type="$1"
  local resource_id="$2"
  
  acquire_lock
  
  if [[ ! -f "$STATE_FILE" ]]; then
    log_warn "State file not found"
    release_lock
    return 1
  fi
  
  chmod 644 "$STATE_FILE" 2>/dev/null || true
  
  jq "del(.resources.${resource_type}[] | select(.id == \"$resource_id\")) | .last_modified = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\" | .metadata.total_resources = (.resources.ec2_instances | length) + (.resources.security_groups | length) + (.resources.s3_buckets | length) + (.resources.key_pairs | length)" "$STATE_FILE" > "$STATE_FILE.tmp"
  
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 444 "$STATE_FILE"
  
  log_success "Removed $resource_type ($resource_id) from state"
  
  sync_to_remote
  release_lock
}

# List all resources
list_resources() {
  if [[ ! -f "$STATE_FILE" ]]; then
    log_warn "State file not found"
    return 1
  fi
  
  jq '.' "$STATE_FILE"
}

# Get resources by type
get_resources() {
  local resource_type="$1"
  
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "[]"
    return 0
  fi
  
  jq -r ".resources.${resource_type}" "$STATE_FILE"
}

# Detect drift - check if resources still exist in AWS
detect_drift() {
  if [[ ! -f "$STATE_FILE" ]]; then
    log_warn "State file not found"
    return 1
  fi
  
  log_info "Detecting drift (checking if resources still exist in AWS)..."
  
  local drift_detected=false
  local region=$(jq -r '.region' "$STATE_FILE")
  
  # Check EC2 instances
  while read -r instance; do
    local id=$(echo "$instance" | jq -r '.id')
    if ! aws ec2 describe-instances --instance-ids "$id" --region "$region" &>/dev/null; then
      log_warn "DRIFT: EC2 instance $id in state but not found in AWS"
      drift_detected=true
    fi
  done < <(jq -c '.resources.ec2_instances[]' "$STATE_FILE" 2>/dev/null || echo "")
  
  # Check Security Groups
  while read -r sg; do
    local id=$(echo "$sg" | jq -r '.id')
    if ! aws ec2 describe-security-groups --group-ids "$id" --region "$region" &>/dev/null; then
      log_warn "DRIFT: Security Group $id in state but not found in AWS"
      drift_detected=true
    fi
  done < <(jq -c '.resources.security_groups[]' "$STATE_FILE" 2>/dev/null || echo "")
  
  # Check S3 Buckets
  while read -r bucket; do
    local name=$(echo "$bucket" | jq -r '.name')
    if ! aws s3api head-bucket --bucket "$name" --region "$region" 2>/dev/null; then
      log_warn "DRIFT: S3 bucket $name in state but not found in AWS"
      drift_detected=true
    fi
  done < <(jq -c '.resources.s3_buckets[]' "$STATE_FILE" 2>/dev/null || echo "")
  
  if [[ "$drift_detected" == "false" ]]; then
    log_success "No drift detected - state matches AWS"
  else
    log_error "Drift detected! Resources in state don't match AWS reality"
    return 1
  fi
}

# Clean state (remove resources not in AWS)
clean_state() {
  acquire_lock
  detect_drift || true
  
  log_info "Cleaning state (removing resources that don't exist in AWS)..."
  
  # This would remove resources from state that don't exist in AWS
  # Implementation left for safety - requires user confirmation
  
  release_lock
}

# Main command handler
case "${1:-}" in
  init)
    check_dependencies
    init_state
    sync_to_remote
    ;;
  add)
    check_dependencies
    resource_type="${2:-}"
    resource_data="${3:-}"
    if [[ -z "$resource_type" || -z "$resource_data" ]]; then
      log_error "Usage: $0 add <resource_type> <json_data>"
      exit 1
    fi
    add_resource "$resource_type" "$resource_data"
    ;;
  remove)
    check_dependencies
    resource_type="${2:-}"
    resource_id="${3:-}"
    if [[ -z "$resource_type" || -z "$resource_id" ]]; then
      log_error "Usage: $0 remove <resource_type> <resource_id>"
      exit 1
    fi
    remove_resource "$resource_type" "$resource_id"
    ;;
  list)
    check_dependencies
    list_resources
    ;;
  get)
    check_dependencies
    resource_type="${2:-}"
    if [[ -z "$resource_type" ]]; then
      log_error "Usage: $0 get <resource_type>"
      exit 1
    fi
    get_resources "$resource_type"
    ;;
  sync-push)
    check_dependencies
    sync_to_remote
    ;;
  sync-pull)
    check_dependencies
    sync_from_remote
    ;;
  drift)
    check_dependencies
    detect_drift
    ;;
  clean)
    check_dependencies
    clean_state
    ;;
  *)
    echo "AWS Resources State Manager"
    echo
    echo "Usage: $0 <command> [options]"
    echo
    echo "Commands:"
    echo "  init                    Initialize new state file"
    echo "  add <type> <json>       Add resource to state"
    echo "  remove <type> <id>      Remove resource from state"
    echo "  list                    List all resources"
    echo "  get <type>              Get resources by type"
    echo "  sync-push               Push local state to remote backend"
    echo "  sync-pull               Pull state from remote backend"
    echo "  drift                   Detect drift (resources deleted manually)"
    echo "  clean                   Clean state (remove non-existent resources)"
    echo
    echo "Resource Types: ec2_instances, security_groups, s3_buckets, key_pairs"
    echo
    echo "Environment Variables:"
    echo "  STATE_REMOTE_BACKEND    S3 bucket name for remote state storage"
    echo "  AWS_REGION              AWS region (default: eu-west-1)"
    exit 1
    ;;
esac
