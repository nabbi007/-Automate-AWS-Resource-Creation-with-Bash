#!/bin/bash
# dry_run_manager.sh - Centralized dry-run management for AWS operations
# Provides dry-run capabilities for EC2, S3, security groups, and other AWS resources
# Usage: source ./dry_run_manager.sh
# Then use: dry_run_flag() or dry_run_info() in your scripts

set -euo pipefail

readonly DRY_RUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DRY_RUN_LOG_DIR="${DRY_RUN_SCRIPT_DIR}/../logs"
readonly DRY_RUN_LOG_FILE="${DRY_RUN_LOG_DIR}/dry_run_audit.log"

# Initialize dry-run audit log
mkdir -p "$DRY_RUN_LOG_DIR" 2>/dev/null || true
touch "$DRY_RUN_LOG_FILE" 2>/dev/null || true

# Color codes for dry-run output
readonly DRY_RUN_BLUE='\033[0;34m'
readonly DRY_RUN_YELLOW='\033[1;33m'
readonly DRY_RUN_GREEN='\033[0;32m'
readonly DRY_RUN_RED='\033[0;31m'
readonly DRY_RUN_CYAN='\033[0;36m'
readonly DRY_RUN_NC='\033[0m'

# Global dry-run flag
DRY_RUN="${DRY_RUN:-false}"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Enable dry-run mode
enable_dry_run() {
  DRY_RUN="true"
  dry_run_log "DRY_RUN mode ENABLED"
  printf "%b" "${DRY_RUN_YELLOW}[DRY-RUN MODE ENABLED] No actual changes will be made${DRY_RUN_NC}\n"
}

# Disable dry-run mode
disable_dry_run() {
  DRY_RUN="false"
  dry_run_log "DRY_RUN mode DISABLED"
  printf "%b" "${DRY_RUN_GREEN}[DRY-RUN MODE DISABLED] Real changes will be executed${DRY_RUN_NC}\n"
}

# Check if dry-run is enabled
is_dry_run() {
  [[ "$DRY_RUN" == "true" ]]
}

# Log dry-run operations to audit file
dry_run_log() {
  local message="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$DRY_RUN_LOG_FILE"
}

# Print dry-run info message
dry_run_info() {
  local message="$1"
  printf "%b" "${DRY_RUN_CYAN}[DRY-RUN] $message${DRY_RUN_NC}\n"
  dry_run_log "INFO: $message"
}

# Print dry-run warning
dry_run_warn() {
  local message="$1"
  printf "%b" "${DRY_RUN_YELLOW}[DRY-RUN WARNING] $message${DRY_RUN_NC}\n"
  dry_run_log "WARN: $message"
}

# Print dry-run success
dry_run_success() {
  local message="$1"
  printf "%b" "${DRY_RUN_GREEN}[DRY-RUN SIMULATION] $message${DRY_RUN_NC}\n"
  dry_run_log "SUCCESS: $message"
}

# Return the --dry-run flag if dry-run is enabled (for AWS CLI commands)
dry_run_flag() {
  if is_dry_run; then
    echo "--dry-run"
  fi
}

# ============================================================================
# EC2 DRY-RUN OPERATIONS
# ============================================================================

# Simulate EC2 instance creation
simulate_ec2_creation() {
  local instance_type="$1"
  local ami_id="$2"
  local key_name="$3"
  local region="${4:-eu-west-1}"
  
  dry_run_info "Simulating EC2 instance creation"
  dry_run_info "  Instance Type: $instance_type"
  dry_run_info "  AMI ID: $ami_id"
  dry_run_info "  Key Name: $key_name"
  dry_run_info "  Region: $region"
  
  # Run AWS dry-run check
  # AWS returns exit code 0 for DryRun operations with successful validation
  # The error message contains "DryRunOperation" when it would succeed
  local output
  output=$(aws ec2 run-instances \
    --instance-type "$instance_type" \
    --image-id "$ami_id" \
    --key-name "$key_name" \
    --region "$region" \
    --dry-run 2>&1 || true)
  
  # Check if output contains DryRunOperation (successful dry-run check)
  if echo "$output" | grep -q "DryRunOperation\|would have succeeded"; then
    dry_run_success "EC2 instance creation would succeed"
    return 0
  # Also check for UnauthorizedOperation which means validation passed but permission denied
  elif echo "$output" | grep -q "UnauthorizedOperation"; then
    dry_run_warn "EC2 instance creation would fail - insufficient permissions"
    return 1
  else
    # If we get here, check if it's a configuration error
    dry_run_warn "EC2 instance creation validation: $(echo "$output" | head -1)"
    return 1
  fi
}

# Simulate EC2 instance termination
simulate_ec2_termination() {
  local instance_id="$1"
  local region="${2:-eu-west-1}"
  
  dry_run_info "Simulating EC2 instance termination: $instance_id"
  
  local output
  output=$(aws ec2 terminate-instances \
    --instance-ids "$instance_id" \
    --region "$region" \
    --dry-run 2>&1 || true)
  
  if echo "$output" | grep -q "DryRunOperation\|would have succeeded"; then
    dry_run_success "EC2 instance termination would succeed"
    return 0
  else
    dry_run_warn "EC2 instance termination would fail"
    return 1
  fi
}

# ============================================================================
# S3 DRY-RUN OPERATIONS
# ============================================================================

# Simulate S3 bucket creation
simulate_s3_creation() {
  local bucket_name="$1"
  local region="${2:-eu-west-1}"
  
  dry_run_info "Simulating S3 bucket creation: $bucket_name"
  dry_run_info "  Region: $region"
  
  # S3 doesn't support --dry-run directly, so we validate bucket name and check if it exists
  local output
  output=$(aws s3api head-bucket --bucket "$bucket_name" --region "$region" 2>&1 || true)
  
  if echo "$output" | grep -q "404"; then
    dry_run_success "S3 bucket creation would succeed (bucket name available)"
    return 0
  elif echo "$output" | grep -q "403"; then
    dry_run_warn "S3 bucket '$bucket_name' exists but access denied"
    return 1
  elif [[ -z "$output" ]]; then
    dry_run_warn "S3 bucket '$bucket_name' already exists (you own it)"
    return 1
  else
    dry_run_warn "S3 bucket check failed: $(echo "$output" | head -1)"
    return 1
  fi
}

# Simulate S3 bucket deletion
simulate_s3_deletion() {
  local bucket_name="$1"
  local region="${2:-eu-west-1}"
  
  dry_run_info "Simulating S3 bucket deletion: $bucket_name"
  
  if aws s3api head-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null; then
    local object_count
    object_count=$(aws s3 ls "s3://$bucket_name" --recursive --summarize --region "$region" 2>/dev/null | grep "Total Objects" | awk '{print $NF}' || echo "0")
    
    dry_run_success "S3 bucket deletion would succeed"
    dry_run_info "  Objects to delete: $object_count"
    return 0
  else
    dry_run_warn "S3 bucket not found or inaccessible"
    return 1
  fi
}

# ============================================================================
# SECURITY GROUP DRY-RUN OPERATIONS
# ============================================================================

# Simulate security group creation
simulate_security_group_creation() {
  local group_name="$1"
  local description="$2"
  local region="${3:-eu-west-1}"
  
  dry_run_info "Simulating security group creation: $group_name"
  dry_run_info "  Description: $description"
  dry_run_info "  Region: $region"
  
  local output
  output=$(aws ec2 create-security-group \
    --group-name "$group_name" \
    --description "$description" \
    --region "$region" \
    --dry-run 2>&1 || true)
  
  if echo "$output" | grep -q "DryRunOperation\|would have succeeded"; then
    dry_run_success "Security group creation would succeed"
    return 0
  elif echo "$output" | grep -q "UnauthorizedOperation"; then
    dry_run_warn "Security group creation would fail - insufficient permissions"
    return 1
  else
    dry_run_warn "Security group creation validation: $(echo "$output" | head -1)"
    return 1
  fi
}

# Simulate security group deletion
simulate_security_group_deletion() {
  local group_id="$1"
  local region="${2:-eu-west-1}"
  
  dry_run_info "Simulating security group deletion: $group_id"
  
  local output
  output=$(aws ec2 delete-security-group \
    --group-id "$group_id" \
    --region "$region" \
    --dry-run 2>&1 || true)
  
  if echo "$output" | grep -q "DryRunOperation\|would have succeeded"; then
    dry_run_success "Security group deletion would succeed"
    return 0
  else
    dry_run_warn "Security group deletion would fail (may have dependencies)"
    return 1
  fi
}

# ============================================================================
# GENERIC COMMAND WRAPPER
# ============================================================================

# Execute command with dry-run support
# Usage: dry_run_execute "command description" "aws s3api create-bucket ..."
dry_run_execute() {
  local description="$1"
  local command="$2"
  
  if is_dry_run; then
    dry_run_info "$description (DRY-RUN MODE)"
    dry_run_info "Command would be: $command"
    
    # For AWS CLI commands, try to add --dry-run if applicable
    if echo "$command" | grep -q "aws ec2\|aws s3api"; then
      local dry_run_cmd
      dry_run_cmd=$(echo "$command" | sed 's/^\(aws ec2 [^ ]*\)/\1 --dry-run/' 2>/dev/null || echo "$command")
      
      if eval "$dry_run_cmd" 2>&1 | grep -q "DryRunOperation\|would"; then
        dry_run_success "$description - validation passed"
        return 0
      else
        dry_run_warn "$description - validation failed"
        return 1
      fi
    fi
    return 0
  else
    # Real execution
    eval "$command"
  fi
}

# ============================================================================
# DRY-RUN REPORT GENERATION
# ============================================================================

# Generate dry-run report
generate_dry_run_report() {
  local report_file="${DRY_RUN_LOG_DIR}/dry_run_report_$(date +%Y%m%d_%H%M%S).txt"
  
  printf "%b" "${DRY_RUN_BLUE}======================================\n"
  printf "%b" "DRY-RUN AUDIT REPORT\n"
  printf "%b" "======================================${DRY_RUN_NC}\n"
  printf "%b" "Report generated: $(date '+%Y-%m-%d %H:%M:%S')\n"
  printf "%b" "Location: $report_file\n\n"
  
  printf "%b" "Recent audit log entries:\n"
  tail -20 "$DRY_RUN_LOG_FILE" | while read -r line; do
    printf "%b" "${DRY_RUN_CYAN}$line${DRY_RUN_NC}\n"
  done
  
  # Save report
  {
    echo "======================================="
    echo "DRY-RUN AUDIT REPORT"
    echo "======================================="
    echo "Report generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Full audit log:"
    cat "$DRY_RUN_LOG_FILE"
  } > "$report_file"
  
  printf "%b" "\n${DRY_RUN_GREEN}Report saved to: $report_file${DRY_RUN_NC}\n"
}

# ============================================================================
# BANNER & INITIALIZATION
# ============================================================================

# Print dry-run mode banner
print_dry_run_banner() {
  if is_dry_run; then
    printf "%b" "${DRY_RUN_YELLOW}"
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                     🔒 DRY-RUN MODE ACTIVE 🔒                 ║
║                                                                ║
║  NO ACTUAL CHANGES WILL BE MADE TO YOUR AWS RESOURCES         ║
║  This is a simulation to validate your operations             ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
    printf "%b" "${DRY_RUN_NC}"
  fi
}

# Auto-detect dry-run from command line
parse_dry_run_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n)
        enable_dry_run
        ;;
      --no-dry-run|--execute)
        disable_dry_run
        ;;
    esac
  done
}

# Export functions for use in sourced scripts
export -f enable_dry_run
export -f disable_dry_run
export -f is_dry_run
export -f dry_run_log
export -f dry_run_info
export -f dry_run_warn
export -f dry_run_success
export -f dry_run_flag
export -f simulate_ec2_creation
export -f simulate_ec2_termination
export -f simulate_s3_creation
export -f simulate_s3_deletion
export -f simulate_security_group_creation
export -f simulate_security_group_deletion
export -f dry_run_execute
export -f generate_dry_run_report
export -f print_dry_run_banner
export -f parse_dry_run_args
