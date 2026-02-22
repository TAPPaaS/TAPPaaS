#!/usr/bin/env bash
# TAPPaaS Test - Debian Image VM Installation
#
# Creates a Debian VM from cloud image
# Usage: ./install-debian.sh <vmname>
# Example: ./install-debian.sh test-debian

set -e

. /home/tappaas/bin/copy-update-json.sh
. /home/tappaas/bin/common-install-routines.sh
check_json /home/tappaas/config/$1.json || exit 1

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
MGMT="mgmt"

# Copy the VM config and create VM
scp "/home/tappaas/config/$1.json" "root@${NODE}.${MGMT}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${MGMT}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"
ssh "root@${NODE}.${MGMT}.internal" "rm /root/tappaas/$1.json"

echo -e "\nVM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}, in Zone: ${ZONE0NAME}"
