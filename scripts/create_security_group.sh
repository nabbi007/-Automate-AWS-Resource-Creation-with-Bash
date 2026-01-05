#!/bin/bash
# AWS Security Group Creation Script - Professional Edition
# Creates EC2 security groups with logging and error handling

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
readonly LOG_FILE="${LOG_DIR}/automation.log"

REGION="${AWS_REGION:-eu-west-1}"
SG_NAME="${SG_NAME:-devops-sg}"
DESCRIPTION="${SG_DESCRIPTION:-Security group for Automation Lab}"
VPC_ID="${VPC_ID:-}"
SG_ID=""

# Initialize logging
mkdir -p "$LOG_DIR" || { echo "ERROR: Cannot create log directory" >&2; exit 1; }
touch "$LOG_FILE" || { echo "ERROR: Cannot create log file" >&2; exit 1; }

log() {
  local level="$1" msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR" "$1"
  if [[ -n "$SG_ID" ]]; then
    log "WARN" "Cleaning up security group: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
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

log "INFO" "Starting Security Group creation process"
log "INFO" "Region: $REGION, Name: $SG_NAME"

# Check if SG already exists
if SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null); then
  if [[ "$SG_ID" != "None" ]] && [[ -n "$SG_ID" ]]; then
    log "WARN" "Security group '$SG_NAME' already exists: $SG_ID"
  fi
fi

# Create security group if not exists
if [[ -z "$SG_ID" ]] || [[ "$SG_ID" == "None" ]]; then
  create_args=("--group-name" "$SG_NAME" "--description" "$DESCRIPTION" "--region" "$REGION")
  [[ -n "$VPC_ID" ]] && create_args+=("--vpc-id" "$VPC_ID")
  
  SG_ID=$(aws ec2 create-security-group "${create_args[@]}" --query 'GroupId' --output text 2>&1) || \
    error_exit "Failed to create security group"
  
  log "INFO" "Security Group created: $SG_ID"
  
  # Tag the security group
  aws ec2 create-tags --resources "$SG_ID" --region "$REGION" \
    --tags Key=Name,Value="$SG_NAME" Key=Project,Value=AutomationLab \
    Key=CreatedDate,Value="$(date -u +'%Y-%m-%d')" 2>&1 || \
    error_exit "Failed to tag security group"
  
  log "INFO" "Security Group tagged successfully"
fi

# Authorize inbound rules (only if not already authorized)
for port in 22 80; do
  protocol="tcp"
  if aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==$port && IpProtocol=='$protocol']" \
    --output text 2>/dev/null | grep -q "tcp"; then
    log "WARN" "Rule for port $port already exists"
    continue
  fi
  
  log "INFO" "Authorizing port $port ($protocol)..."
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol "$protocol" --port "$port" --cidr 0.0.0.0/0 \
    --region "$REGION" &>/dev/null || error_exit "Failed to authorize port $port"
done

log "INFO" "Security Group setup completed successfully"
log "INFO" "Security Group ID: $SG_ID"

aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" --output table

exit 0
