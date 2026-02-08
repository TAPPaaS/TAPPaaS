#!/usr/bin/env bash
# TAPPaaS Module Update Template
#
# < Update the following lines to match your project >
# Update a TAPPaaS Module
# It assumes that you are in the install directory

set -e

if update-json.sh $1; then
    # TODO update the VM and firewall/proxy config based on any changes
    echo "Updated JSON configuration for $1"
fi
. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' '$1')"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
MGMT="mgmt"

# TODO: insert instructions to update the module here

# rebuild the nixos configuration
# Rebuild NixOS configuration, reboot VM, and fix DHCP hostname
/home/tappaas/bin/rebuild-nixos.sh "${VMNAME}" "${VMID}" "${NODE}" "./$1.nix"

# Update HA configuration (creates/updates/removes based on HANode field)
/home/tappaas/bin/update-HA.sh $1

echo -e "\nVM update completed successfully."