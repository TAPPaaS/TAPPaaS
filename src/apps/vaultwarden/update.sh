#!/usr/bin/env bash
#
# TAPPaaS Vaultwarden VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh vaultwarden
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get imageType to determine post-install steps
VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' 'NONE')"

echo ""
info "${BOLD}Post-Install Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"

echo ""
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
    info "  HA Node: ${HANODE}"
fi
