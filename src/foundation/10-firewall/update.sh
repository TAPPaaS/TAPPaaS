#!/usr/bin/env bash
# TAPPaaS Firewall Module Update
#
# Updates the OPNsense firewall software via SSH
#
# Note: OPNsense presents a menu when logging in interactively (option 8 = shell).
# When SSH is used with a command argument, it bypasses the menu and runs directly.

set -e

FIREWALL_FQDN="firewall.mgmt.internal"

echo "Updating OPNsense firewall..."

# Check SSH access
echo "Checking SSH access to firewall..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$FIREWALL_FQDN" echo "ok" >/dev/null 2>&1; then
    echo "Error: Cannot connect to firewall via SSH"
    exit 1
fi
echo "SSH access confirmed"

# Update OPNsense packages
# opnsense-update updates the base system and packages
echo "Running opnsense-update..."
ssh root@"$FIREWALL_FQDN" "opnsense-update -p" || {
    echo "Warning: Package update returned non-zero exit code"
}

# Check if a reboot is required
echo "Checking if reboot is required..."
REBOOT_REQUIRED=$(ssh root@"$FIREWALL_FQDN" "if [ -f /var/run/reboot_required ]; then echo 'yes'; else echo 'no'; fi")

if [ "$REBOOT_REQUIRED" = "yes" ]; then
    echo "Warning: Firewall reboot is required to complete the update"
    echo "Please schedule a maintenance window to reboot the firewall"
else
    echo "No reboot required"
fi

echo "Firewall update completed"
