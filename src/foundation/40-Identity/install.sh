#!/usr/bin/env bash
# install the identity foundation: create VM, run nixos-rebuild, for vm
# It assumes that you are in the install directory

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"

# clone the nixos template
scp "$1.json" "root@${NODE}.${ZONE0NAME}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${ZONE0NAME}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"
# rebuild the nixos configuration
nixos-rebuild --target-host "tappaas@${VMNAME}.${ZONE0NAME}.internal" --use-remote-sudo switch -I "nixos-config=./${VMNAME}.nix"

echo -e "\nIdentity VM installation completed successfully."