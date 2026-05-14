#!/usr/bin/env bash
#
# TAPPaaS logging VM update
#
# Update VM and apply module specific updates.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh logging
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
# Resolve HA node: on a single-node cluster get_default_ha_node returns empty,
# and get_config_value aborts when both key-missing AND default-empty. Pass a
# non-empty placeholder so the banner is optional rather than fatal.
HANODE_DEFAULT="$(get_default_ha_node "$NODE")"
HANODE="$(get_config_value 'HANode' "${HANODE_DEFAULT:-NONE}")"

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

echo ""
info "${BOLD}Next steps${CL}"
info "  - Retrieve the initial Grafana admin password:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo cat /root/grafana-admin-password.initial"
info "      Then change it in the UI and:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo rm /root/grafana-admin-password.initial"
info "  - Forward OPNsense syslog (RFC 5425 over TLS recommended; RFC 5424/TCP supported) to ${VMNAME}.${ZONE0NAME}.internal:1514"
info "  - Other VMs: install a Promtail client pointing at http://${VMNAME}.${ZONE0NAME}.internal:3100"
