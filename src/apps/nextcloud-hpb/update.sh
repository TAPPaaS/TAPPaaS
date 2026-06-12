#!/usr/bin/env bash
# TAPPaaS Module: nextcloud-hpb — Update
#
# Nextcloud Talk High-Performance Backend (nextcloud-spreed-signaling + NATS loopback)
#
# Module-specific update steps beyond the NixOS OS update (which is handled
# by the templates:nixos dependency service updater before this script runs):
# - Re-sync the coturn TURN secret in case it was rotated since install.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh nextcloud-hpb

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-nextcloud-hpb}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"

# Variant-aware host — VMNAME/ZONE0NAME come from the flattened (variant) $JSON,
# never hardcode the base name or zone (the VM may be nextcloud-hpb-test.srv).
HPB_HOST="${VMNAME}.${ZONE0NAME}.internal"
COTURN_MGMT_SECRETS="/home/tappaas/secrets/coturn.env"
# Runtime secrets directory — must match secretsDir in nextcloud-hpb.nix
HPB_SECRETS_DIR="/var/lib/nextcloud-hpb/secrets"

# Recreate-safe SSH: clear any stale host key for the (possibly redeployed) HPB VM,
# then accept-new persists the current key — keeps verification, no strict-check trip.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
ssh-keygen -R "${HPB_HOST}" >/dev/null 2>&1 || true

echo ""
info "${BOLD}Module Update: nextcloud-hpb${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"

# ── Re-sync COTURN_SECRET from management plane → HPB VM (rotation-safe) ─────
echo ""
info "${BOLD}Re-syncing coturn TURN secret to HPB VM…${CL}"

COTURN_SECRET=""
if [[ -f "${COTURN_MGMT_SECRETS}" ]]; then
    COTURN_SECRET=$(grep '^COTURN_SECRET=' "${COTURN_MGMT_SECRETS}" | cut -d= -f2- || true)
fi

if [[ -n "${COTURN_SECRET}" ]]; then
    ssh "${SSH_OPTS[@]}" "tappaas@${HPB_HOST}" \
        "printf '%s\n' '${COTURN_SECRET}' \
           | sudo tee ${HPB_SECRETS_DIR}/turn-secret > /dev/null \
         && sudo chown nextcloud-spreed-signaling:nextcloud-spreed-signaling \
              ${HPB_SECRETS_DIR}/turn-secret \
         && sudo chmod 400 ${HPB_SECRETS_DIR}/turn-secret \
         && sudo systemctl restart nextcloud-spreed-signaling.service" && \
        info "  TURN secret synced to runtime plane; nextcloud-spreed-signaling restarted." || \
        warn "  Failed to sync TURN secret — signaling will use stale secret until fixed."
else
    warn "  COTURN_SECRET not found in ${COTURN_MGMT_SECRETS}."
    warn "  Ensure coturn is installed first, then re-run: update-module.sh nextcloud-hpb"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${GN}✓${CL} ${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
