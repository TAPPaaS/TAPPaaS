#!/usr/bin/env bash
#
# TAPPaaS Test - VM Installation
#
# Creates a VM and applies OS-specific configuration based on imageType.
# Supports NixOS (clone), Debian/Ubuntu (img), and handles HA if configured.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh test-nixos
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source install-vm.sh to create the VM and get config values
# shellcheck source=/dev/null
. /home/tappaas/bin/install-vm.sh

# Get imageType to determine post-install steps
IMAGE_TYPE="$(get_config_value 'imageType' 'clone')"
HANODE="$(get_config_value 'HANode' 'NONE')"

echo ""
echo "=== Post-Install Configuration ==="
echo "VM: ${VMNAME} (VMID: ${VMID})"
echo "Image Type: ${IMAGE_TYPE}"

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
