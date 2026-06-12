#!/usr/bin/env bash
#
# TAPPaaS Module: euro-office — Update
#
# Euro-Office DocumentServer — collaborative document editing platform
#
# Pulls the latest DocumentServer container image inside the VM and restarts
# the service, then syncs the JWT secret to Nextcloud.
#
# NixOS OS updates are handled by the templates:nixos dependency (update-service.sh).
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh euro-office
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-euro-office}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"
# Image is pinned declaratively in euro-office.nix (single source of truth).
# Keep this value identical to euro-office.nix so the manual pull/restart below
# refreshes the same immutable tag (idempotent for a pinned tag).
CONTAINER_IMAGE="ghcr.io/euro-office/documentserver:v9.3.1"

echo ""
info "${BOLD}euro-office Update${CL}"
info "  VM:    ${VMNAME} (VMID: ${VMID})"
info "  Node:  ${NODE}"
info "  Zone:  ${ZONE0NAME}"
info "  Image: ${CONTAINER_IMAGE}"

# ── Step 1: Pull latest DocumentServer container image and restart ────────────
echo ""
info "${BOLD}Pulling DocumentServer image and restarting service…${CL}"
if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
    "tappaas@${VMNAME}.${ZONE0NAME}.internal" \
    "sudo podman pull ${CONTAINER_IMAGE} \
     && sudo systemctl restart podman-euro-office"; then
    info "  Container image updated and service restarted successfully."
else
    warn "  Failed to pull/restart euro-office container — service may be running on the previous image."
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
