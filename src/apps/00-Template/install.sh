#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# < Update the following lines to match your project, current code is generic example code that works for many modules >
# install and configure a Module
# It assumes that you are in the install directory

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"

# copy the VM template
scp "$1.json" "root@${NODE}.${ZONE0NAME}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${ZONE0NAME}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"

# rebuild the nixos configuration
# TODO remove if module is not a NixOS VM
nixos-rebuild --target-host "tappaas@${VMNAME}.${ZONE0NAME}.internal" --use-remote-sudo switch -I "nixos-config=./${VMNAME}.nix"

echo -e "\nVM installation completed successfully."