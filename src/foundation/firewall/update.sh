#!/usr/bin/env bash
# TAPPaaS Firewall Module Update
#
# Updates the OPNsense firewall software via SSH and applies zone configuration.
#
# When firewallType is "NONE" (no OPNsense deployed), this script skips all
# OPNsense-specific operations and prints a reminder.
#
# Note: Connectivity checks (ping, SSH) are handled by update-module.sh
# via the pre-update test-module.sh call before this script runs.
#
# Note: OPNsense presents a menu when logging in interactively (option 8 = shell).
# When SSH is used with a command argument, it bypasses the menu and runs directly.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

readonly CONFIG_DIR="/home/tappaas/config"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
FIREWALL_FQDN="firewall.mgmt.internal"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — OPNsense is not managed by TAPPaaS."
    warn "Skipping firewall update. Manage your firewall manually."
    exit 0
fi

# ── Apply zone configuration ────────────────────────────────────────

info "Applying zone configuration..."
/home/tappaas/bin/zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute

# ── OPNsense update ─────────────────────────────────────────────────

info "Updating OPNsense (base, kernel, and packages)..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" || {
        warn "OPNsense update returned non-zero exit code"
    }
else
    ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" 2>&1 | while IFS= read -r _; do
        printf "."
    done || {
        echo ""
        warn "OPNsense update returned non-zero exit code"
    }
    echo ""
fi

# ── Check if reboot is required ─────────────────────────────────────

info "Checking if reboot is required..."
RUNNING_KERNEL=$(ssh root@"$FIREWALL_FQDN" "uname -r")
INSTALLED_KERNEL=$(ssh root@"$FIREWALL_FQDN" "freebsd-version -k")

if [[ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL" ]]; then
    warn "Firewall reboot is required to complete the update"
    warn "  Running kernel:   $RUNNING_KERNEL"
    warn "  Installed kernel: $INSTALLED_KERNEL"
    warn "Please schedule a maintenance window to reboot the firewall"
else
    info "No reboot required"
fi

info "${GN}✓${CL} Firewall update completed"
