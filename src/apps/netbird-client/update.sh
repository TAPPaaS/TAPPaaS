#!/usr/bin/env bash
#
# TAPPaaS Identity VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh test-nixos
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get imageType to determine post-install steps
VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' 'NONE')"

echo ""
echo "=== Post-Install Configuration ==="
echo "VM: ${VMNAME} (VMID: ${VMID})"

echo ""
echo "=== Installation Complete ==="
echo "VM: ${VMNAME} (VMID: ${VMID})"
echo "Node: ${NODE}"
echo "Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
    echo "HA Node: ${HANODE}"
fi
