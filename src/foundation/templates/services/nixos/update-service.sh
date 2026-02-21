#!/usr/bin/env bash
#
# TAPPaaS Templates NixOS Service - Update
#
# Runs OS-level updates on a consuming module's NixOS VM.
# Reads the module's JSON config to determine VM details and calls update-os.sh.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Updates the NixOS configuration for the specified module."
    exit 1
fi

MODULE_NAME="$1"

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"

# Run OS-specific update (auto-detects NixOS vs Debian)
/home/tappaas/bin/update-os.sh "${VMNAME}" "${VMID}" "${NODE}"
