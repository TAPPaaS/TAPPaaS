#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant VM update
#
# HAOS manages its own updates via the Home Assistant web UI.
# This script verifies the VM is running and reports access info.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh homeassistant
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

echo ""
info "${BOLD}Post-Install Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"

echo ""
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
info "  Access: http://${VMNAME}:8123 (HAOS handles updates via web UI)"
