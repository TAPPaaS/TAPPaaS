#!/usr/bin/env bash
#
# TAPPaaS Firewall Service - Update
#
# Updates firewall rules for a consuming module.
# When firewallType is "NONE", prints a reminder for manual configuration.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

MODULE="${1:-unknown}"
FIREWALL_JSON="/home/tappaas/config/firewall.json"

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    echo -e "\033[33m[WARN]\033[m firewall:firewall update-service for ${MODULE}: firewallType=NONE"
    echo -e "\033[33m[WARN]\033[m Ensure firewall rules for module '${MODULE}' are configured on your firewall."
    exit 0
fi

echo "firewall:firewall update-service called for module: ${MODULE} (not yet implemented)"
exit 0
