#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# This script automates VM restoration from PBS backups
# Run this from tappaas-cicd as the tappaas user
#
# Usage: ./restore.sh [options]
#   -v, --vmid <vmid>           VMID to restore (required)
#   -n, --node <node>           Target Proxmox node (default: tappaas1)
#   -s, --storage <storage>     Target storage for VM (default: original)
#   -b, --backup-id <id>        Specific backup ID to restore (default: latest)
#   -l, --list                  List available backups for a VMID
#   --list-all                  List all available backups
#   -h, --help                  Show this help message

function show_help() {
  cat << EOF
TAPPaaS PBS Restore Script

Usage: $0 [options]

Options:
  -v, --vmid <vmid>           VMID to restore (required for restore)
  -n, --node <node>           Target Proxmox node (default: tappaas1)
  -s, --storage <storage>     Target storage for VM (default: original)
  -b, --backup-id <id>        Specific backup ID to restore (default: latest)
  -l, --list                  List available backups for a VMID (requires -v)
  --list-all                  List all available backups
  -h, --help                  Show this help message

Examples:
  # List all backups
  $0 --list-all

  # List backups for specific VM
  $0 --vmid 101 --list

  # Restore latest backup of VMID 101 to tappaas1
  $0 --vmid 101

  # Restore specific backup to tappaas2
  $0 --vmid 101 --node tappaas2 --backup-id vm/101/2025-01-26T21:00:00Z

  # Restore to different storage
  $0 --vmid 101 --storage tanka2
EOF
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
}

function cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    popd >/dev/null 2>&1 || true
    rm -rf $TEMP_DIR
  fi
}

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Save original arguments and set $1 to module name for common-install-routines.sh
ORIGINAL_ARGS=("$@")
set -- "backup" "$@"

# Source common routines (expects $1 to be module name)
. /home/tappaas/bin/common-install-routines.sh

# Restore original arguments
set -- "${ORIGINAL_ARGS[@]}"

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_CONFIG="$SCRIPT_DIR/backup.json"

PBS_NODE="$(get_config_value 'node' 'tappaas1')"
ZONE="$(get_config_value 'zone0' 'mgmt')"
STORAGE_NAME="tappaas_backup"

# Default values
TARGET_NODE="tappaas1"
VMID=""
TARGET_STORAGE=""
BACKUP_ID=""
LIST_MODE=false
LIST_ALL_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--vmid)
      VMID="$2"
      shift 2
      ;;
    -n|--node)
      TARGET_NODE="$2"
      shift 2
      ;;
    -s|--storage)
      TARGET_STORAGE="$2"
      shift 2
      ;;
    -b|--backup-id)
      BACKUP_ID="$2"
      shift 2
      ;;
    -l|--list)
      LIST_MODE=true
      shift
      ;;
    --list-all)
      LIST_ALL_MODE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# List all backups
if [ "$LIST_ALL_MODE" = true ]; then
  info "${BOLD}Listing all backups from PBS...${CL}"

  # Check if PBS storage is configured
  if ! ssh root@${TARGET_NODE}.${ZONE}.internal "pvesm status 2>/dev/null | grep -q ${STORAGE_NAME}"; then
    echo "${RD}Error: PBS storage '${STORAGE_NAME}' is not configured in Proxmox${CL}"
    echo "Please run ./configure.sh first to set up the PBS storage backend."
    exit 1
  fi

  # Check if PBS storage is active
  STORAGE_STATUS=$(ssh root@${TARGET_NODE}.${ZONE}.internal "pvesm status 2>&1 | grep ${STORAGE_NAME}" || true)
  if echo "$STORAGE_STATUS" | grep -q "error fetching"; then
    echo "${RD}Error: PBS storage is configured but cannot connect to the PBS server${CL}"
    echo "This usually means:"
    echo "  1. The PBS server hasn't been installed yet (run: cd ~/TAPPaaS/src/foundation/backup && ./install.sh)"
    echo "  2. The DNS entry for the PBS server doesn't exist (run: ./configure.sh)"
    echo "  3. The PBS server is not running on ${PBS_NODE}.${ZONE}.internal"
    exit 1
  fi

  # List backups from PBS storage
  ssh root@${TARGET_NODE}.${ZONE}.internal "pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --content backup" 2>/dev/null || {
    echo "${RD}Error: Failed to list backups${CL}"
    echo "No backups found in PBS storage '${STORAGE_NAME}'"
    exit 1
  }
  exit 0
fi

# List backups for specific VMID
if [ "$LIST_MODE" = true ]; then
  if [ -z "$VMID" ]; then
    echo "Error: --vmid required when using --list"
    show_help
    exit 1
  fi

  info "${BOLD}Listing backups for VMID ${VMID}...${CL}"
  ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# List backups for this VMID from PBS
pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID}
EOF
  exit 0
fi

# Validate required parameters for restore
if [ -z "$VMID" ]; then
  echo "Error: --vmid is required for restore operation"
  show_help
  exit 1
fi

info "${BOLD}Starting restore process for VMID ${VMID}...${CL}"

# Get backup information
info "Fetching backup information..."
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# If no specific backup ID provided, find the latest
if [ -z "$BACKUP_ID" ]; then
  info "Finding latest backup for VMID ${VMID}..."
  BACKUP_ID=$(ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Get the latest backup volume name
pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID} \
  | grep volid | tail -1 | awk '{print \$3}' | tr -d ',"'
EOF
)

  if [ -z "$BACKUP_ID" ]; then
    echo "${RD}Error: No backups found for VMID ${VMID}${CL}"
    exit 1
  fi
  info "Latest backup found: ${BACKUP_ID}"
else
  info "Using specified backup: ${BACKUP_ID}"
fi

# Check if VM already exists
info "Checking if VMID ${VMID} already exists..."
VM_EXISTS=$(ssh root@${TARGET_NODE}.${ZONE}.internal "qm status ${VMID} 2>&1 >/dev/null && echo 'yes' || echo 'no'")

if [ "$VM_EXISTS" = "yes" ]; then
  info "VM ${VMID} already exists on ${TARGET_NODE}"
  read -p "Do you want to overwrite it? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled by user"
    exit 0
  fi
  info "Stopping and removing existing VM ${VMID}..."
  ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Stop VM if running
qm stop ${VMID} || true
sleep 2
# Destroy VM
qm destroy ${VMID}
EOF
fi

# Perform the restore
info "Restoring VM ${VMID} from backup..."

# Construct the volume ID (format: storage:backup/path)
# If BACKUP_ID doesn't start with "backup/", add it
if [[ "${BACKUP_ID}" == backup/* ]]; then
  VOLID="${STORAGE_NAME}:${BACKUP_ID}"
else
  VOLID="${STORAGE_NAME}:backup/${BACKUP_ID}"
fi
info "Using volume ID: ${VOLID}"

# Build restore options
RESTORE_OPTS=""
if [ -n "$TARGET_STORAGE" ]; then
  RESTORE_OPTS="--storage ${TARGET_STORAGE}"
  info "Target storage: ${TARGET_STORAGE}"
fi

# Try different restore methods based on available commands
# Capture the SSH output to check for errors
RESTORE_OUTPUT=$(ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e

# Clean up any stale lock files for this VMID
if [ -f /var/lock/qemu-server/lock-${VMID}.conf ]; then
  echo "Removing stale lock file for VM ${VMID}..."
  rm -f /var/lock/qemu-server/lock-${VMID}.conf
fi

# Unlock the VM if it's locked
if qm status ${VMID} >/dev/null 2>&1; then
  echo "Unlocking VM ${VMID}..."
  qm unlock ${VMID} 2>/dev/null || true
fi

# Capture restore output for error checking
RESTORE_TMP=\$(mktemp)

if [ -n "${TARGET_STORAGE}" ]; then
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${VMID} --archive ${VOLID} --storage ${TARGET_STORAGE} --force 1 2>&1 | tee \$RESTORE_TMP
else
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${VMID} --archive ${VOLID} --force 1 2>&1 | tee \$RESTORE_TMP
fi

# Check for errors in restore output
if grep -qi "error\|timeout\|failed" \$RESTORE_TMP; then
  echo "RESTORE_ERRORS_DETECTED"
  if grep -qi "storage.*lock\|can't lock.*storage" \$RESTORE_TMP; then
    echo "STORAGE_LOCK_ERROR"
  fi
fi

rm -f \$RESTORE_TMP
EOF
)

# Check for errors
if echo "$RESTORE_OUTPUT" | grep -q "STORAGE_LOCK_ERROR"; then
  echo "${RD}Error: Storage lock timeout during restore${CL}"
  echo "The target storage '${TARGET_STORAGE}' is currently locked by another operation."
  echo ""
  echo "Solutions:"
  echo "  1. Wait a few minutes and try again"
  echo "  2. Try without --storage option to use original storage location"
  echo "  3. Choose a different target storage"
  echo ""
  echo "Note: VM ${VMID} was partially created but disks were not fully restored."
  echo "You may need to run: ssh root@${TARGET_NODE}.${ZONE}.internal qm destroy ${VMID}"
  exit 1
elif echo "$RESTORE_OUTPUT" | grep -q "RESTORE_ERRORS_DETECTED"; then
  echo "${RD}Error: Restore completed with errors${CL}"
  echo "Check the output above for details."
  echo "VM ${VMID} may not be fully functional."
  exit 1
fi

info "\n${GN}Restore completed successfully!${CL}"
echo
echo "VM ${VMID} has been restored to ${TARGET_NODE}"
echo
read -p "Do you want to start the VM now? (yes/no): " START_VM
if [ "$START_VM" = "yes" ]; then
  info "Starting VM ${VMID}..."
  ssh root@${TARGET_NODE}.${ZONE}.internal "qm start ${VMID}"
  echo "${GN}VM ${VMID} started successfully${CL}"
else
  echo "VM ${VMID} is ready but not started. Start it manually when ready."
fi
