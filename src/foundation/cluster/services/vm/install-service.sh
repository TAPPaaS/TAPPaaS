#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Install
#
# Creates a VM on the Proxmox cluster for a consuming module.
# Based on the install-vm.sh script.
#
# Usage: install-service.sh <module-name>
# Arguments:
#   module-name - Name of the module that depends on this service
#                 (must have a <module-name>.json in /home/tappaas/config)
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Creates a VM for the specified module."
    exit 1
fi

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
