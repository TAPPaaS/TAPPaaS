#!/usr/bin/env bash
# TAPPaaS Firewall Module Update
#
# Updates the OPNsense firewall software via SSH and applies zone configuration.
#
# Note: OPNsense presents a menu when logging in interactively (option 8 = shell).
# When SSH is used with a command argument, it bypasses the menu and runs directly.

set -euo pipefail

FIREWALL_FQDN="firewall.mgmt.internal"

echo "Updating OPNsense firewall..."

# Apply zone configuration if the firewall is reachable
echo "Applying zone configuration..."
if ping -c 1 -W 1 "$FIREWALL_FQDN" >/dev/null 2>&1; then
    /home/tappaas/bin/zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute
else
    echo "Warning: Zones not applied because firewall $FIREWALL_FQDN is unreachable."
fi

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
echo "Updating OPNsense (base, kernel, and packages)..."
ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" || {
    echo "Warning: OPNsense update returned non-zero exit code"
}

# Check if a reboot is required by comparing running vs installed kernel
echo "Checking if reboot is required..."
RUNNING_KERNEL=$(ssh root@"$FIREWALL_FQDN" "uname -r")
INSTALLED_KERNEL=$(ssh root@"$FIREWALL_FQDN" "freebsd-version -k")

if [ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL" ]; then
    echo "Warning: Firewall reboot is required to complete the update"
    echo "  Running kernel:   $RUNNING_KERNEL"
    echo "  Installed kernel: $INSTALLED_KERNEL"
    echo "Please schedule a maintenance window to reboot the firewall"
else
    echo "No reboot required"
fi

echo "Firewall update completed"
