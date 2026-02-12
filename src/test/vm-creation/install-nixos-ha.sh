#!/usr/bin/env bash
# TAPPaaS Test - NixOS Clone VM Installation with HA
#
# Creates a NixOS VM by cloning the tappaas-nixos template,
# applies the NixOS configuration via nixos-rebuild,
# and configures HA on the specified HANode
# Usage: ./install-nixos-ha.sh <vmname>
# Example: ./install-nixos-ha.sh test-nixos-ha

set -e

. /home/tappaas/bin/install-vm.sh

# Rebuild NixOS configuration, reboot VM, and fix DHCP hostname
/home/tappaas/bin/rebuild-nixos.sh "${VMNAME}" "${VMID}" "${NODE}" "./${VMNAME}.nix"

# Update HA configuration (creates/updates/removes based on HANode field)
HANODE="$(get_config_value 'HANode' '')"
if [ -n "$HANODE" ]; then
  echo -e "\nConfiguring HA for VM ${VMNAME} (VMID: ${VMID}) on HA Node: ${HANODE}..."
  /home/tappaas/bin/update-HA.sh "$1"
else
  echo -e "\nNo HA Node specified for VM ${VMNAME} (VMID: ${VMID}), skipping HA configuration..."
fi

echo -e "\nNixOS VM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}, in Zone: ${ZONE0NAME}"
