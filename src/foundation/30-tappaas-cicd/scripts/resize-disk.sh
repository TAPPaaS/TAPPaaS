#!/usr/bin/env bash
# TAPPaaS Disk Resize Script
#
# Resizes the disk of a VM both in Proxmox and inside the VM filesystem.
# Usage: ./resize-disk.sh <vmname> <new-size>
# Example: ./resize-disk.sh nextcloud 50G
#
# Arguments:
#   vmname    - Name of the VM (must have a JSON config in /home/tappaas/config/)
#   new-size  - New disk size (e.g., 50G, 100G, 1T)

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
  echo "Usage: $0 <vmname> <new-size>"
  echo "Example: $0 nextcloud 50G"
  exit 1
fi

VMNAME="$1"
NEW_SIZE="$2"

# Validate size format
if ! [[ "$NEW_SIZE" =~ ^[0-9]+[GMTK]$ ]]; then
  error "Invalid size format: $NEW_SIZE. Use format like 50G, 100G, 1T"
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

# Convert size to bytes for comparison
size_to_bytes() {
  local size="$1"
  local num="${size%[GMTK]}"
  local unit="${size: -1}"
  case "$unit" in
    G) echo $((num * 1024 * 1024 * 1024)) ;;
    M) echo $((num * 1024 * 1024)) ;;
    T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
    K) echo $((num * 1024)) ;;
    *) echo "$num" ;;
  esac
}

# Get VM configuration
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
CURRENT_SIZE="$(get_config_value 'diskSize' '8G')"

info "${BOLD}TAPPaaS Disk Resize${CL}"
info "VM: $VMNAME (VMID: $VMID) on $NODE"
info "Current configured size: $CURRENT_SIZE"
info "New size: $NEW_SIZE"

# Get actual current disk size from Proxmox
ACTUAL_SIZE=$(ssh -o StrictHostKeyChecking=no "root@${NODE}.mgmt.internal" \
  "qm config $VMID | grep -oP 'scsi0:.*size=\K[0-9]+[GMTK]?'" 2>/dev/null || echo "unknown")
info "Actual Proxmox disk size: $ACTUAL_SIZE"

# Compare sizes
CURRENT_BYTES=$(size_to_bytes "$ACTUAL_SIZE")
NEW_BYTES=$(size_to_bytes "$NEW_SIZE")

if [ "$NEW_BYTES" -le "$CURRENT_BYTES" ]; then
  error "New size ($NEW_SIZE) must be larger than current size ($ACTUAL_SIZE). Disk shrinking is not supported."
fi

# Resize disk in Proxmox
info "Resizing disk in Proxmox from $ACTUAL_SIZE to $NEW_SIZE..."
ssh -o StrictHostKeyChecking=no "root@${NODE}.mgmt.internal" \
  "qm resize $VMID scsi0 $NEW_SIZE" >/dev/null

info "Proxmox disk resize complete."

# Resize filesystem inside VM
info "Resizing filesystem inside VM..."

TARGET="${VMNAME}.${ZONE0}.internal"
MAX_WAIT=30
WAITED=0

# Wait for VM to be reachable
while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o BatchMode=yes "tappaas@${TARGET}" "exit 0" &>/dev/null; do
  sleep 2
  WAITED=$((WAITED + 2))
  if [ $WAITED -ge $MAX_WAIT ]; then
    warn "VM $VMNAME not reachable via SSH after ${MAX_WAIT}s"
    warn "The Proxmox disk has been resized. Please resize the filesystem manually."
    exit 0
  fi
done

# Detect OS type
OS_ID=$(ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" \
  "grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '\"'" 2>/dev/null)
info "Detected OS: $OS_ID"

# Find root device (resolve UUID symlinks)
ROOT_DEV=$(ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "
  dev=\$(findmnt -n -o SOURCE /)
  if [[ \"\$dev\" == /dev/disk/by-* ]]; then
    readlink -f \"\$dev\"
  else
    echo \"\$dev\"
  fi
" 2>/dev/null)
info "Root device: $ROOT_DEV"

# Extract disk and partition number
if [[ "$ROOT_DEV" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"
  PARTNUM="${BASH_REMATCH[2]}"
elif [[ "$ROOT_DEV" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"
  PARTNUM="${BASH_REMATCH[2]}"
else
  warn "Cannot parse root device $ROOT_DEV"
  warn "The Proxmox disk has been resized. Please resize the filesystem manually."
  exit 0
fi
info "Disk: $DISK, Partition: $PARTNUM"

# Detect filesystem type
FSTYPE=$(ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "findmnt -n -o FSTYPE /" 2>/dev/null)
info "Filesystem type: $FSTYPE"

# Resize based on OS
case "$OS_ID" in
  nixos)
    info "Resizing partition on NixOS using sfdisk..."
    ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "
      echo ', +' | sudo sfdisk --no-reread -N ${PARTNUM} ${DISK} 2>/dev/null || true
      sudo partprobe ${DISK} 2>/dev/null || sudo partx -u ${DISK} 2>/dev/null || true
    " 2>/dev/null
    if [ "$FSTYPE" == "ext4" ]; then
      info "Resizing ext4 filesystem..."
      ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "sudo resize2fs ${ROOT_DEV}" 2>/dev/null
    else
      warn "Unsupported filesystem $FSTYPE, partition resized but filesystem not expanded"
    fi
    ;;
  debian|ubuntu)
    info "Resizing partition on Debian/Ubuntu using growpart..."
    ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "
      sudo growpart ${DISK} ${PARTNUM} 2>/dev/null || true
    " 2>/dev/null
    if [ "$FSTYPE" == "ext4" ]; then
      info "Resizing ext4 filesystem..."
      ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "sudo resize2fs ${ROOT_DEV}" 2>/dev/null
    else
      warn "Unsupported filesystem $FSTYPE, partition resized but filesystem not expanded"
    fi
    ;;
  *)
    warn "Unsupported OS '$OS_ID'"
    warn "The Proxmox disk has been resized. Please resize the filesystem manually."
    exit 0
    ;;
esac

# Verify new size
NEW_FS_SIZE=$(ssh -o StrictHostKeyChecking=no "tappaas@${TARGET}" "df -BG / | tail -1 | awk '{print \$2}'" 2>/dev/null | tr -d 'G')
info "New filesystem size: ${NEW_FS_SIZE}G"

# Update JSON configuration with new size
info "Updating JSON configuration..."
jq --arg size "$NEW_SIZE" '.diskSize = $size' "$JSON_CONFIG" > "${JSON_CONFIG}.tmp" && \
  mv "${JSON_CONFIG}.tmp" "$JSON_CONFIG"

info "${BOLD}Disk resize completed successfully!${CL}"
info "VM $VMNAME disk resized from $ACTUAL_SIZE to $NEW_SIZE"
