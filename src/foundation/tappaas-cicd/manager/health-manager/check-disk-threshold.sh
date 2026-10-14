#!/usr/bin/env bash
# TAPPaaS Disk Threshold Check Script
#
# Checks if a VM's disk usage exceeds a threshold and grows the disk — the
# same decision auto-grow.sh makes on every update (#100), with a threshold
# chosen here.
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

# The decision is auto-grow.sh's (#100) — the same one every module update makes:
# threshold, growth step, diskSizeMax, and room on the disk's pool (and on the
# HA replica's). Asked in --check mode, so it only answers; the grow below goes
# through module modify as before.
AUTOGROW="$(dirname "$(readlink -f "$0")")/../../../cluster/services/vm/auto-grow.sh"
[ -x "$AUTOGROW" ] || AUTOGROW=/home/tappaas/TAPPaaS/src/foundation/cluster/services/vm/auto-grow.sh

info "${BOLD}TAPPaaS Disk Threshold Check${CL}"
info "VM: $VMNAME  Threshold: ${THRESHOLD}%"

DECISION="$(TAPPAAS_AUTOGROW_THRESHOLD="$THRESHOLD" OPT_DEBUG=1 "$AUTOGROW" --check "$VMNAME" 2>&1)" || true
echo "$DECISION" | sed 's/^/  /'
NEW_SIZE="$(echo "$DECISION" | sed -n 's/.*would grow — diskSize [0-9]*G→\([0-9]*G\).*/\1/p' | head -1)"
if [ -z "$NEW_SIZE" ]; then
  info "No grow: see the reason above."
  exit 0
fi
ACTUAL_SIZE="$(echo "$DECISION" | sed -n 's/.*would grow — diskSize \([0-9]*G\)→.*/\1/p' | head -1)"
DISK_USAGE="$(echo "$DECISION" | sed -n 's/.*: \/ is \([0-9]*\)% full.*/\1/p' | head -1)"

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
