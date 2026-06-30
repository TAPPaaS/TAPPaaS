#!/usr/bin/env bash
#
# TAPPaaS deCONZ module — update / post-install
#
# Updates the VM and applies module-specific steps (ConBee II USB passthrough).
#
# Usage: ./update.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"

# ── FOUNDATION-CANDIDATE: usb-passthrough → cluster:vm / Create-TAPPaaS-VM.sh ──
# Module-local ConBee II USB attach (option 1). The engine has no usb field for
# cluster:vm yet, so the module attaches the stick itself — engine UNTOUCHED,
# mirroring the hass 0.2.0 module-local qm pattern (CONFIG-disk).
# PROMOTE to foundation when a 2nd USB module appears: add a `usb` field to the
# cluster:vm schema (module-fields.json) + emit this qm-set inside
# Create-TAPPaaS-VM.sh, then delete this block. Find all candidates:
#   grep -rn FOUNDATION-CANDIDATE
# Idempotent (qm set re-applies cleanly). Single ConBee -> vendor:product stable.
CONBEE_USB="1cf1:0030"   # dresden elektronik ConBee II — verify: lsusb / qm config <id>
# DECONZ_SKIP_USB=1 -> phase-0 smoke deploy: bring up the VM + service WITHOUT
# grabbing the ConBee (which is still on the live VM 200 / ZHA). Production
# Zigbee stays untouched; deCONZ runs with no coordinator until the cutover.
if [[ "${DECONZ_SKIP_USB:-0}" == "1" ]]; then
  warn "DECONZ_SKIP_USB=1 — skipping ConBee USB attach (smoke/no-coordinator deploy). Production Zigbee untouched."
elif command -v qm >/dev/null 2>&1 && qm config "${VMID}" >/dev/null 2>&1; then
  if qm config "${VMID}" | grep -q "^usb0:.*${CONBEE_USB}"; then
    info "ConBee II (${CONBEE_USB}) already attached to VM ${VMID} (usb0)."
  else
    info "Attaching ConBee II (${CONBEE_USB}) to VM ${VMID} as usb0…"
    qm set "${VMID}" -usb0 "host=${CONBEE_USB}"
    # The device binds on next VM start; deCONZ (services.deconz.device) then
    # finds it at /dev/serial/by-id. A VM restart may be required to make the
    # passthrough live if the VM is already running.
    # TODO (deploy): restart the VM after first attach if the device is absent.
  fi
else
  warn "qm not available or VM ${VMID} not found — skipping USB attach (run on the cluster node)."
fi
# ──────────────────────────────────────────────────────────────────────────────

echo ""
info "${BOLD}deCONZ Post-Install Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
info "  Pair devices + create scenes in Phoscon: http://${VMNAME}.${ZONE0NAME}.internal:8080"
info "  HA: add the deCONZ integration -> host ${VMNAME}.${ZONE0NAME}.internal, port 8080 (ws 8443)."

echo ""
info "${BOLD}Installation Complete${CL}"
