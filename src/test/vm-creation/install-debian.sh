#!/usr/bin/env bash
# TAPPaaS Test - Debian Image VM Installation
#
# Creates a Debian VM from cloud image
# Usage: ./install-debian.sh <vmname>
# Example: ./install-debian.sh test-debian

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

echo -e "\nDebian VM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}."
echo "Zone: ${ZONE0NAME}"

# Wait for VM to be accessible via SSH
echo -e "\nWaiting for VM to be ready for SSH..."
sleep 30

# SSH into the VM and install QEMU guest agent
echo "Installing QEMU guest agent..."
ssh "tappaas@${VMNAME}.${ZONE0NAME}.internal" "sudo apt-get update && sudo apt-get install -y qemu-guest-agent"

# Restart the VM
echo "Restarting VM ${VMNAME}..."
ssh "root@${NODE}.${MGMT}.internal" "qm restart ${VMID}"

echo -e "\nVM ${VMNAME} restarted with QEMU guest agent installed."
