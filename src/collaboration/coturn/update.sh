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

debug "*** Starting coturn update"
debug "  VM:   ${VMNAME} (VMID: ${VMID})"
debug "  Node: ${NODE}"
debug "  Zone: ${ZONE0NAME}"

# NixOS OS update is handled by templates:nixos update-service.sh before this
# script runs. The module-specific converge is the public TURN name: its
# default (turn.<site domain>), re-asserted every run.
debug "Converging the public TURN name"
# shellcheck source=public-name.sh
. "${SCRIPT_DIR}/public-name.sh"
coturn_converge_public_name "${1:-coturn}" "${VMNAME}.${ZONE0NAME}.internal"

# ── Summary ──────────────────────────────────────────────────────────────────
debug "Update Complete"
debug "  VM:   ${VMNAME} (VMID: ${VMID})"
debug "  Node: ${NODE}"
debug "  Zone: ${ZONE0NAME}"
