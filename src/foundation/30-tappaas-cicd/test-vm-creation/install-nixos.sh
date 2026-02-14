#!/usr/bin/env bash
# TAPPaaS Test - NixOS Clone VM Installation
#
# Creates a NixOS VM by cloning the tappaas-nixos template,
# applies the NixOS configuration via nixos-rebuild,
# and optionally configures HA if HANode is specified
# Usage: ./install-nixos.sh <vmname>
# Example: ./install-nixos.sh test-nixos

set -e

. /home/tappaas/bin/install-vm.sh

# Rebuild NixOS configuration, reboot VM, and fix DHCP hostname
/home/tappaas/bin/rebuild-nixos.sh "${VMNAME}" "${VMID}" "${NODE}" "./${VMNAME}.nix"

# Update HA configuration if HANode is specified
HANODE="$(get_config_value 'HANode' '')"
if [ -n "$HANODE" ]; then
  echo -e "\nConfiguring HA for VM ${VMNAME} (VMID: ${VMID}) on HA Node: ${HANODE}..."
  /home/tappaas/bin/update-HA.sh "$1"
else
  echo -e "\nNo HA Node specified, skipping HA configuration..."
fi

echo -e "\nNixOS VM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}."
echo "Zone: ${ZONE0NAME}"
