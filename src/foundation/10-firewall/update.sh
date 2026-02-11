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

if update-json.sh firewall; then
    echo "firewall.json updated, applying configuration..."
    # TODO
fi

# Update HA configuration (creates/updates/removes based on HANode field)
/home/tappaas/bin/update-HA.sh firewall


# Check SSH access
echo "Checking SSH access to firewall..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$FIREWALL_FQDN" echo "ok" >/dev/null 2>&1; then
    echo "Error: Cannot connect to firewall via SSH"
    exit 1
fi
echo "SSH access confirmed"

# Update OPNsense using the proper CLI tool
# opnsense-update requires specific flags to actually perform updates:
#   -b  Update base system
#   -k  Update kernel
#   -p  Update packages
#   -f  Force update even if up-to-date
echo "Updating OPNsense (base, kernel, and packages)..."
ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" || {
    echo "Warning: OPNsense update returned non-zero exit code"
}

# Check if a reboot is required
# OPNsense uses configctl firmware reboot to check for pending reboots
# TODO, this code is doing the actual reboot
# echo "Checking if reboot is required..."
# if ssh root@"$FIREWALL_FQDN" "configctl firmware reboot" 2>/dev/null | grep -qi "reboot"; then
#     echo "Warning: Firewall reboot is required to complete the update"
#     echo "Please schedule a maintenance window to reboot the firewall"
# else
#     echo "No reboot required"
# fi

echo "Firewall update completed"
