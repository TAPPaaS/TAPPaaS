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

info "${BOLD}*** Starting euro-office update${CL} (${CONTAINER_IMAGE})"
debug "  VM:    ${VMNAME} (VMID: ${VMID})"
debug "  Node:  ${NODE}"
debug "  Zone:  ${ZONE0NAME}"

# ── Step 1: Pull latest DocumentServer container image and restart ────────────
info "Pulling DocumentServer image and restarting service…"
# The pull writes a "Copying blob <sha>" line per layer, which is progress, not
# news. Dots instead; the whole thing stays in the log, and run_with_dots prints
# its tail if the pull fails. LogLevel=ERROR drops ssh's "Permanently added …
# to the list of known hosts" chatter, which accept-new emits on first contact.
if run_with_dots "/tmp/euro-office-pull.log" \
    ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 \
    "tappaas@${VMNAME}.${ZONE0NAME}.internal" \
    "sudo podman pull ${CONTAINER_IMAGE} \
     && sudo systemctl restart podman-euro-office"; then
    debug "  Container image updated and service restarted successfully."
else
    warn "  Failed to pull/restart euro-office container — service may be running on the previous image."
fi

# ── Summary ──────────────────────────────────────────────────────────────────
debug "${BOLD}Update Complete${CL}"
debug "  VM:   ${VMNAME} (VMID: ${VMID})"
debug "  Node: ${NODE}"
debug "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    debug "  HA Node: ${HANODE}"
fi
