#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# < Update the following lines to match your project, current code is generic example code that works for many modules >
# install and configure a Module
# It assumes that you are in the install directory

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
MGMT="mgmt"

# copy the VM template
scp "$1.json" "root@${NODE}.${MGMT}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${MGMT}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"


# TODO: insert instructions to update the module here

# rebuild the nixos configuration
echo "Waiting for VM to get IP address..."
sleep 30
VMIP=$(ssh "root@${NODE}.${MGMT}.internal" "qm guest cmd ${VMID} network-get-interfaces" | jq -r '.[] | select(.name == "eth0") | ."ip-addresses"[] | select(."ip-address-type" == "ipv4") | ."ip-address"')
echo "VM IP address: ${VMIP}"

nixos-rebuild --target-host "tappaas@${VMIP}" --use-remote-sudo switch -I "nixos-config=./${VMNAME}.nix"


# run the update script as all update actions is also needed at install time
# . ./update.sh

echo -e "\nVM installation completed successfully."