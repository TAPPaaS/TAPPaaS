#!/usr/bin/env bash
#
# TAPPaaS Vaultwarden VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh vaultwarden
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get imageType to determine post-install steps
VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

debug "  ${VMNAME} (VMID ${VMID}) on ${NODE}${HANODE:+, HA ${HANODE}}, zone ${ZONE0NAME}"
install_note "  ${VMNAME} runs on ${NODE}, zone ${ZONE0NAME}: ${VMNAME}.${ZONE0NAME}.internal"
