#!/usr/bin/env bash
# TAPPaaS Disk Threshold Check Script
#
# Checks if a VM's disk usage exceeds a threshold and automatically
# expands the disk by 50% if needed.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Load JSON configuration
JSON_CONFIG="/home/tappaas/config/${VMNAME}.json"
if [ ! -f "$JSON_CONFIG" ]; then
  error "Configuration file not found: $JSON_CONFIG"
fi
JSON=$(cat "$JSON_CONFIG")

function get_config_value() {
  local key="$1"
  local default="$2"
  local value
  if ! echo "$JSON" | jq -e --arg K "$key" 'has($K)' >/dev/null; then
    if [ -z "$default" ]; then
      error "Missing required key '$key' in JSON configuration."
    fi
    value="$default"
  else
    value=$(echo "$JSON" | jq -r --arg KEY "$key" '.[$KEY]')
  fi
  echo -n "$value"
}

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
NODE="$(get_config_value 'node' 'tappaas1')"
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

info "Calculated new size: ${NEW_SIZE} (50% increase from ${ACTUAL_SIZE})"

# Call resize-disk.sh to perform the resize
info "Initiating disk resize..."
if "${SCRIPT_DIR}/resize-disk.sh" "$VMNAME" "$NEW_SIZE"; then
  info "${BOLD}Disk resize completed successfully!${CL}"
  info "VM $VMNAME disk expanded from $ACTUAL_SIZE to $NEW_SIZE"

  # Log the resize event
  LOG_FILE="/home/tappaas/logs/disk-resize.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $VMNAME: Resized from $ACTUAL_SIZE to $NEW_SIZE (usage was ${DISK_USAGE}%, threshold ${THRESHOLD}%)" >> "$LOG_FILE"
else
  error "Disk resize failed for $VMNAME"
fi
