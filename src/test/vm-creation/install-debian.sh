#!/usr/bin/env bash
# TAPPaaS Test - Debian Image VM Installation
#
# Creates a Debian VM from cloud image
# Usage: ./install-debian.sh <vmname>
# Example: ./install-debian.sh test-debian

. /home/tappaas/bin/install-vm.sh

# Wait for VM to be accessible via SSH and get its IP address
echo -e "\nWaiting for VM to boot and configure networking..."
sleep 60

# Get the VM's MAC address and find its IP from the Proxmox node
VM_MAC=$(ssh "root@${NODE}.${MGMT}.internal" "qm config ${VMID} | grep 'net0' | sed -n 's/.*virtio=\([^,]*\).*/\1/p'")
echo "VM MAC address: ${VM_MAC}"

# Query DHCP leases on firewall to find IP (same method as test-vm.sh)
VM_IP=$(
    echo "Looking up IP from DHCP leases..." >&2
    MAC_LOWER=$(echo "${VM_MAC}" | tr '[:upper:]' '[:lower:]')
    for i in {1..40}; do
        IP=$(ssh "root@firewall.${MGMT}.internal" "grep -i '${MAC_LOWER}' /var/db/dnsmasq.leases" 2>/dev/null | awk '{print $3}')
        if [ -n "$IP" ]; then
            echo "$IP"
            break
        fi
        sleep 3
    done
)

if [ -z "$VM_IP" ]; then
    echo "ERROR: Could not determine VM IP address"
    exit 1
fi

echo "VM IP address: ${VM_IP}"

# Update SSH known_hosts for the new IP
ssh-keygen -R "${VM_IP}" 2>/dev/null || true
ssh-keyscan -H "${VM_IP}" >> ~/.ssh/known_hosts 2>/dev/null

# Wait for cloud-init to finish before installing packages
echo "Waiting for cloud-init to finish..."
ssh -o StrictHostKeyChecking=accept-new "tappaas@${VM_IP}" "cloud-init status --wait" || true

# SSH into the VM and install QEMU guest agent
echo "Installing QEMU guest agent..."
ssh "tappaas@${VM_IP}" "sudo apt-get update && sudo apt-get install -y qemu-guest-agent && sudo systemctl start qemu-guest-agent"

# Reboot the VM to enable guest agent
echo "Rebooting VM ${VMNAME}..."
ssh "root@${NODE}.${MGMT}.internal" "qm reboot ${VMID}"

echo -e "\nVM ${VMNAME} installation completed successfully."
echo "QEMU guest agent installed and VM rebooted."
