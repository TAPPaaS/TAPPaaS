#!/usr/bin/env bash
#
# TAPPaaS Vaultwarden VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh vaultwarden
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

# Run OS-specific post-install using update-os.sh
# This script auto-detects NixOS vs Debian and applies appropriate updates
cd "${SCRIPT_DIR}"
/home/tappaas/bin/update-os.sh "${VMNAME}" "${VMID}" "${NODE}"

# Configure HA if HANode is specified
if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
    echo ""
    echo "=== Configuring HA ==="
    echo "HA Node: ${HANODE}"
    /home/tappaas/bin/update-HA.sh "${VMNAME}"
else
    echo ""
    echo "No HA Node specified, skipping HA configuration."
fi

echo ""
echo "=== Installation Complete ==="
echo "VM: ${VMNAME} (VMID: ${VMID})"
echo "Node: ${NODE}"
echo "Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
    echo "HA Node: ${HANODE}"
fi
