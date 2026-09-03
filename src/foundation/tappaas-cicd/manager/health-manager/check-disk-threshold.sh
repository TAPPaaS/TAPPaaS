#!/usr/bin/env bash
# TAPPaaS Disk Threshold Check Script
#
# Checks if a VM's disk usage exceeds a threshold and automatically
# expands the disk by 50% if needed.
#
# The grow is issued as `module-manager module modify <vm> --set diskSize=<new>`
# so config and cluster move together (ADR-020 D9). This script owns the
# DECISION to grow; it does not own the growing.
#
# Usage: ./check-disk-threshold.sh <vmname> <threshold>
# Example: ./check-disk-threshold.sh nextcloud 80
#
# Arguments:
#   vmname     - Name of the VM (must have a JSON config in /home/tappaas/config/)
#   threshold  - Disk usage percentage threshold (e.g., 80 for 80%)
#
# This script is designed to be run from cron for automatic disk management.

set -e

# Color definitions
YW=$(echo "\033[33m")    # Yellow
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
BOLD=$(echo "\033[1m")   # Bold

function info() {
  echo -e "${DGN}${1}${CL}"
}

function warn() {
  echo -e "${YW}[WARN]${CL} ${1}"
}

function error() {
  echo -e "${RD}[ERROR]${CL} ${1}" >&2
  exit 1
}

# Check hostname
if [ "$(hostname)" != "tappaas-cicd" ]; then
  error "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
fi

# Validate arguments
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <vmname> <threshold>"
  echo "Example: $0 nextcloud 80"
  echo ""
  echo "Arguments:"
  echo "  vmname     - Name of the VM"
  echo "  threshold  - Disk usage percentage threshold (1-99)"
  exit 1
fi

VMNAME="$1"
THRESHOLD="$2"

# Validate threshold
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 99 ]; then
  error "Invalid threshold: $THRESHOLD. Must be a number between 1 and 99."
fi

# Load JSON configuration.
#
# The shared helpers are sourced rather than reimplemented here. This script
# previously carried its own get_config_value that read the raw file, which was
# wrong twice over: it saw only FLAT top-level keys, so every Pattern-A module
# (nextcloud keeps diskSize under .config["cluster:vm"]) silently fell through to
# the default; and it never provided get_node_hostname, which line ~107 calls —
# that call has been emitting "command not found" and yielding an empty node
# fallback. common-install-routines.sh provides both, Pattern-A agnostic (#207),
# and auto-loads $JSON normalized from $1.
#
# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

JSON_CONFIG="/home/tappaas/config/${VMNAME}.json"
if [ ! -f "$JSON_CONFIG" ]; then
  error "Configuration file not found: $JSON_CONFIG"
fi

# Convert size string to number in GB
size_to_gb() {
  local size="$1"
  local num="${size%[GMTK]}"
  local unit="${size: -1}"
  case "$unit" in
    G) echo "$num" ;;
    M) echo $((num / 1024)) ;;
    T) echo $((num * 1024)) ;;
    K) echo $((num / 1024 / 1024)) ;;
    *) echo "$num" ;;
  esac
}

# Get VM configuration
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
CURRENT_SIZE="$(get_config_value 'diskSize' '8G')"

TARGET="${VMNAME}.${ZONE0}.internal"

info "${BOLD}TAPPaaS Disk Threshold Check${CL}"
info "VM: $VMNAME (VMID: $VMID)"
info "Threshold: ${THRESHOLD}%"

# Check if VM is reachable
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "tappaas@${TARGET}" "exit 0" &>/dev/null; then
  warn "VM $VMNAME is not reachable via SSH. Skipping check."
  exit 0
fi

# Get current disk usage percentage
DISK_USAGE=$(ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" \
  "df / | tail -1 | awk '{print \$5}'" 2>/dev/null | tr -d '%')

if [ -z "$DISK_USAGE" ]; then
  error "Could not determine disk usage for $VMNAME"
fi

info "Current disk usage: ${DISK_USAGE}%"

# Check if threshold exceeded
if [ "$DISK_USAGE" -lt "$THRESHOLD" ]; then
  info "Disk usage (${DISK_USAGE}%) is below threshold (${THRESHOLD}%). No action needed."
  exit 0
fi

info "${YW}Disk usage (${DISK_USAGE}%) exceeds threshold (${THRESHOLD}%)!${CL}"

# Get current disk size from Proxmox
ACTUAL_SIZE=$(ssh -o StrictHostKeyChecking=no "root@${NODE}.mgmt.internal" \
  "qm config $VMID | grep -oP 'scsi0:.*size=\K[0-9]+[GMTK]?'" 2>/dev/null || echo "$CURRENT_SIZE")

info "Current disk size: $ACTUAL_SIZE"

# Calculate new size (50% increase)
CURRENT_GB=$(size_to_gb "$ACTUAL_SIZE")
INCREASE_GB=$((CURRENT_GB / 2))
# Minimum increase of 5GB
if [ "$INCREASE_GB" -lt 5 ]; then
  INCREASE_GB=5
fi
NEW_GB=$((CURRENT_GB + INCREASE_GB))
NEW_SIZE="${NEW_GB}G"

# Computed from the LIVE size, not config's diskSize: the disk is the truth
# about the disk, and deriving from actual also repairs a config that has fallen
# behind (e.g. a pre-D9 grow that never wrote config back).
info "Calculated new size: ${NEW_SIZE} (50% increase from ${ACTUAL_SIZE})"

# Grow through `module modify --set`, NOT by calling resize-disk.sh directly
# (ADR-020 D9). diskSize is a declared field, so growing it is a declared-field
# change: `--set` writes the new size into the deployed config and then converges
# it through the same gated path every other field change uses. Calling
# resize-disk.sh here would move the CLUSTER without moving the CONFIG, and the
# converge reads config-behind-actual as a SHRINK — which `grow-only` refuses
# (update-disk.sh exit 20), on this pass and on every pass after it, with nothing
# in the loop able to move config forward. This script decides WHEN to grow; the
# change model does the growing.
#
# No --force: a grow is `grow-only` and non-disruptive, so it needs no disruption
# authorization. Forwarding --force would authorize downtime that a disk-usage
# threshold has no business authorizing (ADR-020 D8).
info "Initiating disk grow via module-manager modify..."
if module-manager module modify "$VMNAME" --set "diskSize=${NEW_SIZE}"; then
  info "${BOLD}Disk grow completed successfully!${CL}"
  info "VM $VMNAME disk expanded from $ACTUAL_SIZE to $NEW_SIZE (config and cluster both updated)"

  # Log the resize event
  LOG_FILE="/home/tappaas/logs/disk-resize.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $VMNAME: Resized from $ACTUAL_SIZE to $NEW_SIZE (usage was ${DISK_USAGE}%, threshold ${THRESHOLD}%)" >> "$LOG_FILE"
else
  error "Disk grow failed for $VMNAME — config unchanged if the pre-gate refused, rolled back if the converge did"
fi
