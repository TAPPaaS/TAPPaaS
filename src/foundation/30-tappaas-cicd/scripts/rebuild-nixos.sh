#!/usr/bin/env bash
# TAPPaaS NixOS Rebuild Script
#
# This script handles the nixos-rebuild process for a VM including:
# - Waiting for VM to get an IP address via guest agent
# - Running nixos-rebuild
# - Rebooting the VM
# - Fixing DHCP hostname registration
#
# Usage: rebuild-nixos.sh <vmname> <vmid> <node> <nix-config-path>
# Example: rebuild-nixos.sh myvm 610 tappaas1 ./myvm.nix

set -e

VMNAME="$1"
VMID="$2"
NODE="$3"
NIX_CONFIG="$4"
MGMT="mgmt"

if [ -z "$VMNAME" ] || [ -z "$VMID" ] || [ -z "$NODE" ] || [ -z "$NIX_CONFIG" ]; then
    echo "Usage: rebuild-nixos.sh <vmname> <vmid> <node> <nix-config-path>"
    echo "Example: rebuild-nixos.sh myvm 610 tappaas1 ./myvm.nix"
    exit 1
fi

# Function to get VM IP address via Proxmox guest agent
get_vm_ip() {
    ssh "root@${NODE}.${MGMT}.internal" "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null | \
        jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | \
        head -1
}

# Wait for VM to get IP address
echo "Waiting for VM to get IP address..."
for i in {1..18}; do
    sleep 10
    VMIP=$(get_vm_ip)
    if [ -n "$VMIP" ]; then
        break
    fi
    echo "  Attempt $i: guest agent not ready yet..."
done
if [ -z "$VMIP" ]; then
    echo "ERROR: Could not get VM IP address after 3 minutes"
    exit 1
fi
echo "VM IP address: ${VMIP}"

# Update SSH known_hosts for the new VM
ssh-keygen -R "$VMIP" 2>/dev/null || true
ssh-keyscan -H "$VMIP" >> ~/.ssh/known_hosts 2>/dev/null

# Run nixos-rebuild
echo "Running nixos-rebuild..."
nixos-rebuild --target-host "tappaas@${VMIP}" --use-remote-sudo switch -I "nixos-config=${NIX_CONFIG}"

# Reboot the VM to apply the new configuration
echo "Rebooting VM to apply configuration..."
ssh "root@${NODE}.${MGMT}.internal" "qm reboot ${VMID}"

# Wait for VM to come back up
echo "Waiting 60 seconds for VM to restart..."
sleep 60

# Get the VM IP again (may have changed after reboot)
for i in {1..6}; do
    VMIP=$(get_vm_ip)
    if [ -n "$VMIP" ]; then
        break
    fi
    echo "  Attempt $i: waiting for guest agent..."
    sleep 10
done
if [ -z "$VMIP" ]; then
    echo "ERROR: Could not get VM IP address after reboot"
    exit 1
fi
echo "VM IP address after reboot: ${VMIP}"

# Update SSH known_hosts again (host key may have changed)
ssh-keygen -R "$VMIP" 2>/dev/null || true
ssh-keyscan -H "$VMIP" >> ~/.ssh/known_hosts 2>/dev/null

# Fix DHCP hostname registration
# Find the ethernet connection name using nmcli
echo "Fixing DHCP hostname registration..."
ETH_CONNECTION=$(ssh "tappaas@${VMIP}" "nmcli -t -f NAME,TYPE connection show" | grep ethernet | cut -d: -f1 | head -1)
ETH_DEVICE=$(ssh "tappaas@${VMIP}" "nmcli -t -f DEVICE,TYPE device status" | grep ethernet | cut -d: -f1 | head -1)

if [ -n "$ETH_CONNECTION" ] && [ -n "$ETH_DEVICE" ]; then
    echo "  Ethernet connection: ${ETH_CONNECTION}"
    echo "  Ethernet device: ${ETH_DEVICE}"
    ssh "tappaas@${VMIP}" "sudo nmcli connection modify '${ETH_CONNECTION}' ipv4.dhcp-hostname \"\$(hostname)\""
    ssh "tappaas@${VMIP}" "sudo nmcli device reapply '${ETH_DEVICE}'"
    echo "  DHCP hostname updated to: ${VMNAME}"
else
    echo "  WARNING: Could not find ethernet connection/device for DHCP fix"
fi

echo "NixOS rebuild completed successfully."
