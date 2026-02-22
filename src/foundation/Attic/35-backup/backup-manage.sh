#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# TAPPaaS Backup Management Script
# Provides utilities for managing PBS backups
#
# Usage: ./backup-manage.sh <command> [options]
#
# Commands:
#   list-jobs           List configured backup jobs
#   run-now <vmid>      Run immediate backup for a VM
#   verify <backup-id>  Verify backup integrity
#   prune              Run prune operation
#   gc                 Run garbage collection
#   status             Show PBS status
#   help               Show this help

function show_help() {
  cat << EOF
TAPPaaS Backup Management Script

Usage: $0 <command> [options]

Commands:
  list-jobs                   List all configured backup jobs
  run-now <vmid>              Run immediate backup for a specific VM
  run-now-all                 Run immediate backup for all VMs
  verify <backup-id>          Verify backup integrity
  prune                       Run prune operation on datastore
  gc                          Run garbage collection on datastore
  status                      Show PBS datastore status
  retention                   Show current retention policy
  help                        Show this help message

Examples:
  # List backup jobs
  $0 list-jobs

  # Run immediate backup for VM 101
  $0 run-now 101

  # Backup all VMs immediately
  $0 run-now-all

  # Show PBS status
  $0 status

  # Run prune and garbage collection
  $0 prune && $0 gc
EOF
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  echo -e "\n${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}\n"
}

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

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
DATASTORE_NAME="tappaas_backup"
MGMT_NODE="tappaas1"

COMMAND="${1:-help}"

case "$COMMAND" in
  list-jobs)
    info "${BOLD}Configured backup jobs:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "cat /etc/pve/vzdump.cron"
    echo
    info "${BOLD}Backup job history:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "pvesh get /cluster/backup"
    ;;

  run-now)
    if [ -z "$2" ]; then
      echo "Error: VMID required"
      echo "Usage: $0 run-now <vmid>"
      exit 1
    fi
    VMID="$2"
    info "${BOLD}Running immediate backup for VM ${VMID}...${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "vzdump ${VMID} --storage ${STORAGE_NAME} --mode snapshot --compress zstd"
    info "${GN}Backup completed for VM ${VMID}${CL}"
    ;;

  run-now-all)
    info "${BOLD}Running immediate backup for all VMs...${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "vzdump --all 1 --storage ${STORAGE_NAME} --mode snapshot --compress zstd"
    info "${GN}Backup completed for all VMs${CL}"
    ;;

  verify)
    if [ -z "$2" ]; then
      echo "Error: Backup ID required"
      echo "Usage: $0 verify <backup-id>"
      exit 1
    fi
    BACKUP_ID="$2"
    info "${BOLD}Verifying backup ${BACKUP_ID}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-client verify ${BACKUP_ID}"
    ;;

  prune)
    info "${BOLD}Running prune operation on ${DATASTORE_NAME}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore prune ${DATASTORE_NAME}"
    info "${GN}Prune operation completed${CL}"
    ;;

  gc)
    info "${BOLD}Running garbage collection on ${DATASTORE_NAME}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager garbage-collection start ${DATASTORE_NAME}"
    info "${GN}Garbage collection started${CL}"
    ;;

  status)
    info "${BOLD}PBS Datastore Status:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore list"
    echo
    info "${BOLD}Datastore Usage:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "df -h | grep -E '(Filesystem|${DATASTORE_NAME})'"
    echo
    info "${BOLD}Recent Backups:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "pvesh get /nodes/${MGMT_NODE}/storage/${STORAGE_NAME}/content" | head -20
    ;;

  retention)
    info "${BOLD}Current Retention Policy for ${DATASTORE_NAME}:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore list" | grep -A 10 "${DATASTORE_NAME}"
    ;;

  help|--help|-h)
    show_help
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo
    show_help
    exit 1
    ;;
esac
