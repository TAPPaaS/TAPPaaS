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

# ── Configure OPNsense to forward syslog to this VM ──────────────────
# Idempotent: matches the destination by description ("tappaas-logging").
# Skipped when firewallType != opnsense (deployment uses a different firewall).
echo ""
info "${BOLD}Configure OPNsense syslog forwarding${CL}"

FIREWALL_TYPE="$(get_config_value 'firewallType' 'opnsense')"
SYSLOG_TARGET="${VMNAME}.${ZONE0NAME}.internal"
SYSLOG_DESC="tappaas-logging"

if [[ "${FIREWALL_TYPE}" != "opnsense" ]]; then
    info "  firewallType=${FIREWALL_TYPE} — skipping (configure manually on your firewall)"
elif ! command -v syslog-manager >/dev/null 2>&1; then
    warn "  syslog-manager CLI not found — rebuild the mothership to pick it up"
    warn "  Manual fallback: System → Settings → Logging / Targets → add ${SYSLOG_TARGET}:1514 (TCP, RFC 5424)"
else
    info "  Target: ${SYSLOG_TARGET}:1514 (TCP, RFC 5424)"
    if syslog-manager add-destination \
            --hostname "${SYSLOG_TARGET}" \
            --port 1514 \
            --transport tcp4 \
            --rfc5424 \
            --description "${SYSLOG_DESC}" \
            --no-ssl-verify; then
        if syslog-manager reconfigure --no-ssl-verify; then
            info "  ${GN}✓${CL} OPNsense will now forward syslog to ${SYSLOG_TARGET}:1514"
        else
            warn "  Destination saved but OPNsense reconfigure failed — apply manually in the UI"
        fi
    else
        warn "  Could not add OPNsense syslog destination — configure manually via the UI"
    fi
fi

echo ""
info "${BOLD}Next steps${CL}"
info "  - Retrieve the initial Grafana admin password:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo cat /root/grafana-admin-password.initial"
info "      Then change it in the UI and:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo rm /root/grafana-admin-password.initial"
info "  - Other VMs: install a Promtail client pointing at http://${VMNAME}.${ZONE0NAME}.internal:3100"
