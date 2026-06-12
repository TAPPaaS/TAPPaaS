#!/usr/bin/env bash
#
# TAPPaaS Module: coturn — Update
#
# coturn TURN/STUN server for Nextcloud Talk WebRTC audio/video calls.
#
# Module-specific update steps beyond the NixOS OS update (which is handled
# by the templates:nixos dependency service updater before this script runs).
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh coturn
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck disable=SC2034  # kept for potential use by sourcing scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-coturn}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"

echo ""
info "${BOLD}Module Update: coturn${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"

# NixOS OS update is handled by templates:nixos update-service.sh before this
# script runs. No additional module-specific update steps are needed for
# coturn beyond the NixOS rebuild.
echo ""
info "No module-specific update steps — NixOS OS update handled by dependency layer."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
