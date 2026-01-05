#!/bin/bash
# -------------------------------------------------------------
# Script Name : cleanup_resources.sh
# Purpose     : Remove AWS resources created by Automation Lab
# Author      : Iliasu Abubakar
# -------------------------------------------------------------

set -euo pipefail

# ---------------------- CONFIGURATION -------------------------
LOG_FILE="../logs/automation.log"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
# --------------------------------------------------------------

# ---------------------- FUNCTIONS ------------------------------
log() {
  echo "$(date '+%F %T') [INFO] $1" | tee -a "$LOG_FILE"
}
# --------------------------------------------------------------

log "Starting cleanup of tagged AWS resources"

# Terminate EC2 instances
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

if [[ -n "$INSTANCE_IDS" ]]; then
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
  log "Terminated EC2 instances: $INSTANCE_IDS"
fi

# Delete Security Groups
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
  --query "SecurityGroups[].GroupId" \
  --output text || true)

for SG in $SG_IDS; do
  aws ec2 delete-security-group --group-id "$SG"
  log "Deleted Security Group: $SG"
done

log "Cleanup completed successfully"
