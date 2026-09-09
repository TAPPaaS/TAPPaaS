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
#   -n, --node <node>           Target Proxmox node (default: the first mgmt node from site.json)
#   -s, --storage <storage>     Target storage for VM (default: original)
#   -b, --backup-id <id>        Specific backup ID to restore (default: latest)
#   -t, --target-vmid <vmid>    Restore INTO a different (unused) VMID, leaving the
#                               original untouched. The restored guest is left
#                               STOPPED with fresh MACs. This is how a recovery
#                               path is rehearsed, and how you compare a restore
#                               against a running original before committing.
#   -l, --list                  List available backups for a VMID
#   --list-all                  List all available backups
#   -h, --help                  Show this help message

function show_help() {
  cat << EOF
TAPPaaS PBS Restore Script

Usage: $0 [options]

Options:
  -v, --vmid <vmid>           VMID to restore (required for restore)
  -n, --node <node>           Target Proxmox node (default: the first mgmt node from site.json)
  -s, --storage <storage>     Target storage for VM (default: original)
  -b, --backup-id <id>        Specific backup ID to restore (default: latest)
  -t, --target-vmid <vmid>    Restore into a different, unused VMID (left STOPPED,
                              fresh MACs) instead of over the original
                              A repeated --vmid overrides the earlier one, so a
                              caller that already supplied one (backup-manager
                              restore) can be pointed at a different SOURCE vmid
  -l, --list                  List available backups for a VMID (requires -v)
  --list-all                  List all available backups
  -h, --help                  Show this help message

Examples:
  # List all backups
  $0 --list-all

  # List backups for specific VM
  $0 --vmid 101 --list

  # Restore latest backup of VMID 101 to primary node
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

# Source common routines and load backup module config
. /home/tappaas/bin/common-install-routines.sh
# ha-vm-lib (#434): stopping an HA resource safely. Installed copy first, repo
# copy as the fallback so the script works from a checkout too.
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
elif [[ -r "$(dirname "${BASH_SOURCE[0]}")/../../tappaas-cicd/lib/ha-vm-lib.sh" ]]; then
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../../tappaas-cicd/lib/ha-vm-lib.sh"
fi
JSON_CONFIG="${CONFIG_DIR}/backup.json"
JSON=$(cat "${JSON_CONFIG}")

# The node PBS runs on. ADR-012 §2.1: the RESOLVED node is carried by the
# placement state (`placementState: node:<name>`); `.node` is only the operator's
# discovery constraint and may be empty, so it is a back-compat fallback.
PBS_NODE="$(jq -r '.placementState // empty' "${JSON_CONFIG}" 2>/dev/null | sed -n 's/^node://p')"
[[ -n "${PBS_NODE}" ]] || PBS_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE="$(get_config_value 'zone0' 'mgmt')"
STORAGE_NAME="$(get_config_value 'pbsStorageName' 'tappaas_backup')"  # configurable, issue #199

# Default values
TARGET_NODE="$(get_node_hostname 0)"
VMID=""
TARGET_STORAGE=""
BACKUP_ID=""
TARGET_VMID=""
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
    -t|--target-vmid)
      TARGET_VMID="$2"
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
  # --output-format json, NOT the human table. The old form was
  #   pvesh get ... | grep volid | tail -1 | awk '{print $3}'
  # and `grep volid` matched the TABLE HEADER — the only line containing the
  # word — so it extracted a box-drawing character and restored from a volid
  # that could not exist. The restore then reported success (see below), which
  # is how a backup system convinces you it works while restoring nothing.
  # Newest = highest ctime, not "last line".
  BACKUP_ID=$(ssh -n root@${TARGET_NODE}.${ZONE}.internal \
    "pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID} --output-format json" \
    | jq -r 'sort_by(.ctime) | last | .volid // empty')

  # A volid always looks like <storage>:backup/<type>/<vmid>/<time>. Anything
  # else means the lookup failed, and restoring from it must not be attempted.
  if [ -n "${BACKUP_ID}" ] && ! printf '%s' "${BACKUP_ID}" | grep -qE '^[A-Za-z0-9_.-]+:backup/'; then
    echo "${RD}Error: backup lookup returned something that is not a volume id: '${BACKUP_ID}'${CL}"
    exit 1
  fi

  if [ -z "$BACKUP_ID" ]; then
    echo "${RD}Error: No backups found for VMID ${VMID}${CL}"
    exit 1
  fi
  info "Latest backup found: ${BACKUP_ID}"
else
  info "Using specified backup: ${BACKUP_ID}"
fi

# From here on, VMID is the SOURCE (whose backup we read) and RESTORE_VMID is
# the DESTINATION. They differ only for --target-vmid, whose whole point is to
# leave the original alone — so a rehearsal can never eat the thing it is
# rehearsing the recovery of.
RESTORE_VMID="${TARGET_VMID:-${VMID}}"
if [ -n "${TARGET_VMID}" ]; then
  info "Restoring INTO VMID ${RESTORE_VMID} (source VM ${VMID} is left untouched)"
fi

# Check if the DESTINATION VM already exists
info "Checking if VMID ${RESTORE_VMID} already exists..."
VM_EXISTS=$(ssh root@${TARGET_NODE}.${ZONE}.internal "qm status ${RESTORE_VMID} 2>&1 >/dev/null && echo 'yes' || echo 'no'")

if [ "$VM_EXISTS" = "yes" ]; then
  if [ -n "${TARGET_VMID}" ]; then
    echo "${RD}Error: target VMID ${RESTORE_VMID} is already in use${CL}"
    echo "Pick an unused VMID — --target-vmid exists to avoid destroying anything."
    exit 1
  fi
  info "VM ${RESTORE_VMID} already exists on ${TARGET_NODE}"
  read -p "Do you want to overwrite it? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled by user"
    exit 0
  fi
  # Stopping an HA-managed VM is NOT `qm stop; sleep`. `qm stop` hands a request
  # to the CRM, which completes it on its own schedule — the exact race that
  # left this site's gateway down for 7h41m (#434), which is why ha-vm-lib
  # exists. Drive HA through ha-manager and CONFIRM the transition; only fall
  # back to a direct stop when the resource is genuinely not HA-managed.
  info "Stopping and removing existing VM ${RESTORE_VMID}..."
  if declare -F havm_stop >/dev/null 2>&1; then
    if ! havm_stop "root@${TARGET_NODE}.${ZONE}.internal" "${RESTORE_VMID}" vm "${STOP_TIMEOUT:-180}"; then
      # The resource may have been handed to HA as 'stopped' before the failure;
      # give it back rather than leaving it parked.
      [[ "${HAVM_LAST_STOP_WAS_HA:-0}" -eq 1 ]] \
        && havm_release_ha_stop "root@${TARGET_NODE}.${ZONE}.internal" "vm:${RESTORE_VMID}"
      die "Could not confirm VM ${RESTORE_VMID} stopped — refusing to destroy it. Nothing was changed."
    fi
  else
    warn "ha-vm-lib not available — falling back to a direct stop (unsafe for an HA-managed VM, #434)"
    ssh root@${TARGET_NODE}.${ZONE}.internal "qm stop ${RESTORE_VMID} || true"
    sleep 5
  fi

  # --purge clears the VMID out of backup/replication jobs and HA;
  # --destroy-unreferenced-disks removes disks carrying this VMID that the
  # config no longer references, so a restore does not silently inherit an
  # older incarnation's leftover volumes.
  ssh root@${TARGET_NODE}.${ZONE}.internal \
    "qm destroy ${RESTORE_VMID} --purge --destroy-unreferenced-disks 1" \
    || die "Could not destroy VM ${RESTORE_VMID}"
fi

# Perform the restore
info "Restoring VM ${VMID} from backup into VMID ${RESTORE_VMID}..."

# Normalize whatever form of backup identifier we were given into a volid:
#   tappaas_backup:backup/vm/110/…  already a volid (what --list prints)
#   backup/vm/110/…                 storage-relative path
#   vm/110/…                        the bare snapshot triple
case "${BACKUP_ID}" in
  *:backup/*) VOLID="${BACKUP_ID}" ;;
  backup/*)   VOLID="${STORAGE_NAME}:${BACKUP_ID}" ;;
  *)          VOLID="${STORAGE_NAME}:backup/${BACKUP_ID}" ;;
esac
info "Using volume ID: ${VOLID}"

# A copy restored alongside its original MUST get fresh MAC addresses, or two
# guests answer for the same address the moment either is started.
UNIQUE_OPT=""
[ -n "${TARGET_VMID}" ] && UNIQUE_OPT="--unique 1"

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
if [ -f /var/lock/qemu-server/lock-${RESTORE_VMID}.conf ]; then
  echo "Removing stale lock file for VM ${RESTORE_VMID}..."
  rm -f /var/lock/qemu-server/lock-${RESTORE_VMID}.conf
fi

# Unlock the VM if it's locked
if qm status ${RESTORE_VMID} >/dev/null 2>&1; then
  echo "Unlocking VM ${RESTORE_VMID}..."
  qm unlock ${RESTORE_VMID} 2>/dev/null || true
fi

# Capture restore output AND its real exit code. Piping pvesh into tee used to
# hide the failure: a pipeline exits with tee status, so the remote set -e never
# fired and the only detection left was grepping the output for the word
# "error". A restore that did nothing at all reported success.
# (No backticks in this comment: the heredoc is unquoted, so they would be
# command substitution executed on THIS side.)
RESTORE_TMP=\$(mktemp)
RESTORE_RC=0

if [ -n "${TARGET_STORAGE}" ]; then
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${RESTORE_VMID} --archive ${VOLID} --storage ${TARGET_STORAGE} --force 1 ${UNIQUE_OPT} > \$RESTORE_TMP 2>&1 || RESTORE_RC=\$?
else
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${RESTORE_VMID} --archive ${VOLID} --force 1 ${UNIQUE_OPT} > \$RESTORE_TMP 2>&1 || RESTORE_RC=\$?
fi
cat \$RESTORE_TMP
if [ "\$RESTORE_RC" -ne 0 ]; then
  echo "RESTORE_FAILED_RC=\$RESTORE_RC"
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

# Check for errors. The rc marker is authoritative; the text grep below stays
# as a second net for the cases where pvesh reports trouble but exits 0.
if echo "$RESTORE_OUTPUT" | grep -q "RESTORE_FAILED_RC="; then
  echo "${RD}Error: the restore command failed${CL} ($(echo "$RESTORE_OUTPUT" | grep -o 'RESTORE_FAILED_RC=[0-9]*'))"
  echo "$RESTORE_OUTPUT" | grep -v RESTORE_FAILED_RC | tail -15
  echo
  echo "Nothing was restored into VMID ${RESTORE_VMID}."
  exit 1
fi
if echo "$RESTORE_OUTPUT" | grep -q "STORAGE_LOCK_ERROR"; then
  echo "${RD}Error: Storage lock timeout during restore${CL}"
  echo "The target storage '${TARGET_STORAGE}' is currently locked by another operation."
  echo ""
  echo "Solutions:"
  echo "  1. Wait a few minutes and try again"
  echo "  2. Try without --storage option to use original storage location"
  echo "  3. Choose a different target storage"
  echo ""
  echo "Note: VM ${RESTORE_VMID} was partially created but disks were not fully restored."
  echo "You may need to run: ssh root@${TARGET_NODE}.${ZONE}.internal qm destroy ${RESTORE_VMID}"
  exit 1
elif echo "$RESTORE_OUTPUT" | grep -q "RESTORE_ERRORS_DETECTED"; then
  echo "${RD}Error: Restore completed with errors${CL}"
  echo "Check the output above for details."
  echo "VM ${VMID} may not be fully functional."
  exit 1
fi

# Trust, then verify: ask Proxmox whether the guest is really there. A restore
# that reports success without producing a VM is the one failure mode a backup
# system must never have.
if ! ssh -n root@${TARGET_NODE}.${ZONE}.internal "qm config ${RESTORE_VMID}" >/dev/null 2>&1; then
  echo "${RD}Error: restore reported success but VMID ${RESTORE_VMID} does not exist on ${TARGET_NODE}${CL}"
  exit 1
fi

info "\n${GN}Restore completed successfully!${CL}"
echo
echo "VM ${VMID} has been restored to ${TARGET_NODE} as VMID ${RESTORE_VMID}"
echo
if [ -n "${TARGET_VMID}" ]; then
  echo "It is STOPPED and has fresh MAC addresses. Starting a restored COPY on the"
  echo "same network as its original is how you get two guests answering for one"
  echo "identity — inspect it, then start it deliberately if that is what you want:"
  echo "  ssh root@${TARGET_NODE}.${ZONE}.internal qm start ${RESTORE_VMID}"
  echo "  ssh root@${TARGET_NODE}.${ZONE}.internal qm destroy ${RESTORE_VMID}   # when done"
  exit 0
fi
read -p "Do you want to start the VM now? (yes/no): " START_VM
if [ "$START_VM" = "yes" ]; then
  info "Starting VM ${VMID}..."
  ssh root@${TARGET_NODE}.${ZONE}.internal "qm start ${RESTORE_VMID}"
  echo "${GN}VM ${VMID} started successfully${CL}"
else
  echo "VM ${VMID} is ready but not started. Start it manually when ready."
fi
