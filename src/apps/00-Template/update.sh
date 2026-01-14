#!/usr/bin/env bash
# TAPPaaS Module Update Template
#
# < Update the following lines to match your project >
# Update a TAPPaaS Module
# It assumes that you are in the install directory

set -e

if update-json.sh $1; then
    # TODO update the VM and firewall/proxy config based on any changes
fi
. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' '$1')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"

# TODO: insert instructions to update the module here

# rebuild the nixos configuration
nixos-rebuild --target-host "tappaas@${VMNAME}.${ZONE0NAME}.internal" --use-remote-sudo switch -I "nixos-config=./${VMNAME}.nix"

echo -e "\nVM update completed successfully."