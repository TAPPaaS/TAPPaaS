#!/usr/bin/env bash
#
# TAPPaaS Module: nextcloud — Update
#
# Nextcloud with PostgreSQL and Redis
#
# Module-specific update steps beyond the NixOS OS update (which is handled
# by the templates:nixos dependency service updater before this script runs).
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh nextcloud
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck disable=SC2034  # kept for potential use by sourcing scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-nextcloud}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

echo ""
info "${BOLD}Module Update: nextcloud${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"

# NixOS OS update is handled by templates:nixos update-service.sh before this
# script runs. No additional module-specific update steps are needed for
# nextcloud beyond the NixOS rebuild.
echo ""
info "No module-specific update steps — NixOS update handled by dependency layer."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
