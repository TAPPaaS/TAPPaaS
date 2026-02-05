#!/usr/bin/env bash
# TAPPaaS Test - NixOS Clone VM Installation
#
# Creates a NixOS VM by cloning the tappaas-nixos template
# and applies the NixOS configuration via nixos-rebuild
# Usage: ./install-nixos.sh <vmname>
# Example: ./install-nixos.sh test-nixos

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
MGMT="mgmt"

# Copy the VM config and create VM
scp "$1.json" "root@${NODE}.${MGMT}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${MGMT}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"

# Rebuild NixOS configuration, reboot VM, and fix DHCP hostname
/home/tappaas/bin/rebuild-nixos.sh "${VMNAME}" "${VMID}" "${NODE}" "./${VMNAME}.nix"

echo -e "\nNixOS VM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}."
echo "Zone: ${ZONE0NAME}"
