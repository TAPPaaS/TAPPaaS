#!/usr/bin/env bash
# TAPPaaS Test - Debian Image VM Installation
#
# Creates a Debian VM from cloud image
# Usage: ./install-debian.sh <vmname>
# Example: ./install-debian.sh test-debian

set -e

update-json.sh "$1" || true  # Update JSON if needed, but ignore if .orig exists (user customized)

. /home/tappaas/bin/common-install-routines.sh

check_json "$JSON_CONFIG" || exit 1

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
MGMT="mgmt"

# Copy the VM config and create VM
scp "$1.json" "root@${NODE}.${MGMT}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${MGMT}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"

echo -e "\nVM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}, in Zone: ${ZONE0NAME}"
