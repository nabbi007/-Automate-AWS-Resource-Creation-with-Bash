# AWS Automation Lab

Professional Bash scripts for automated AWS resource management with JSON state tracking and remote backend sync.

**Author:** nabbi007  
**Date:** January 13, 2026

## Features

✅ **Dry-run mode** - Validate operations before execution (like Terraform plan)  
✅ JSON state management (Terraform-style)  
✅ Automatic S3 remote backend with versioning  
✅ Drift detection & cleanup  
✅ Tag-based safety validation  
✅ Idempotent operations  
✅ Automatic state synchronization

## Prerequisites

**Required:**
- Bash (Linux/macOS/WSL/Git Bash)
- AWS CLI v2 ([Install](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- jq (`sudo apt install jq` or `brew install jq`)
- Configured AWS credentials

**Verify:**
```bash
aws --version && aws sts get-caller-identity && jq --version
```

## Quick Start

### 1. Setup
```bash
cd scripts
chmod +x *.sh
export AWS_REGION=eu-west-1  # Optional, defaults to eu-west-1
```

### 2. Create Resources
```bash
# Preview changes first (dry-run mode)
./create_security_group.sh --dry-run
./create_ec2.sh --dry-run
./create_s3_bucket.sh --dry-run

# Actually create resources
./create_security_group.sh
./create_ec2.sh
./create_s3_bucket.sh
```

### 3. View State
```bash
./state_manager.sh list
./state_manager.sh get ec2_instances
```

### 4. Cleanup
```bash
# Preview deletion (dry-run mode)
./cleanup_resources.sh --dry-run

# Actually delete resources
./cleanup_resources.sh
```

## What It Does

| Script | Purpose |
|--------|---------|
| `create_security_group.sh` | Creates security group with ports 22 & 80 open |
| `create_ec2.sh` | Launches EC2 instance with key pair |
| `create_s3_bucket.sh` | Creates S3 bucket with versioning & encryption |
| `cleanup_resources.sh` | Safely deletes all tracked resources |
| `state_manager.sh` | Manages JSON state with remote sync |

## How It Works

1. **First run:** Auto-creates S3 backend bucket with unique name
2. **State tracking:** All resources automatically saved to JSON state
3. **Auto-sync:** State continuously synced to S3 (source of truth)
4. **Safety:** Tag validation + drift detection before deletion
5. **Idempotent:** Safe to run multiple times

## State Management

**Automatic Features:**
- Remote backend bucket auto-created with versioning
- State file read-only (protected from accidents)
- Drift detection (finds manually deleted resources)
- Resource locking (prevents concurrent changes)

**View Resources:**
```bash
./state_manager.sh list                # All resources
./state_manager.sh drift               # Check for drift
./state_manager.sh get security_groups # Specific type
```

## Project Structure

```
aws-automation-lab/
├── scripts/
│   ├── create_*.sh          # Resource creation
│   ├── cleanup_resources.sh # Safe cleanup
│   ├── state_manager.sh     # State management
│   └── dry_run_manager.sh   # Dry-run validation
├── keys/                    # SSH keys (git-ignored)
├── logs/                    # Execution logs
└── .aws-resources.state.json # JSON state (read-only)
```

## Dry-Run Mode

**Test before executing!** All scripts support `--dry-run` flag to validate operations without making changes:

```bash
# Validate EC2 creation
./create_ec2.sh --dry-run

# Validate S3 bucket creation  
./create_s3_bucket.sh --dry-run

# Validate security group creation
./create_security_group.sh --dry-run

# Preview cleanup operations
./cleanup_resources.sh --dry-run
```

**What dry-run checks:**
- ✅ AWS permissions & credentials
- ✅ Resource name conflicts
- ✅ VPC & network availability
- ✅ AMI & instance type validity
- ✅ Existing resources detection

**Exit Codes:**
- `0` = Validation passed (safe to run)
- `1` = Validation failed (fix issues first)

## Screenshots

### STS Identity
![STS](screenshot/sts.png)


### Security Group Creation
![Security Group](screenshot/security_group.png)

### EC2 Instance
![EC2](screenshot/ec2.png)

### S3 Bucket
![S3](screenshot/bucket.png)

### Dry-Run Mode
![EC2 Dry-Run](screenshot/ec2-dry-run.png)
*Validating EC2 instance creation before execution*

![S3 Dry-Run](screenshot/s3-dry-run.png)
*Validating EC2 instance creation before execution*

![Security Group Dry-Run](screenshot/security-dry-run.png)
*Checking security group parameters and permissions*

![Cleanup Dry-Run](screenshot/cleanup-dry-run.png)
*Previewing resources to be deleted*

### Cleanup
![Cleanup](screenshot/cleanup.png)

## Important Notes

⚠️ **Never hard-code AWS credentials** - use `aws configure`  
⚠️ All resources tagged with `Project=AutomationLab` for safety  
⚠️ AMI IDs vary by region - update if needed  
⚠️ State file is read-only to prevent accidental changes

## Troubleshooting

**jq not found:**
```bash
sudo apt install jq  # Ubuntu/Debian
brew install jq      # macOS
```

**State locked:**
```bash
rm -f .state.lock  # Only if no other process running
```

**View logs:**
```bash
tail -f logs/automation.log
```











