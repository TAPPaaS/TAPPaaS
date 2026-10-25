#!/usr/bin/env bash
#
# TAPPaaS Template VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh template
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

# ── REPLACE THE WARNING BELOW WITH THIS MODULE'S OWN UPDATE STEPS ────────
# Everything that must be true after every update, done idempotently
# (ADR-020): the package version, the rendered configuration, the service
# restart. Delete the warning when you write them — while it is here, this
# module takes nothing forward on an update.
# ─────────────────────────────────────────────────────────────────────────

warn "update.sh has not been implemented for this module — it is a template stub, so nothing module-specific was updated. Please contact the module's developer."

# Output (DEVELOP.md, "Output"): one ✓ line per thing this update established
# or checked; the steps at debug; where the module is and how to use it with
# install_note, which shows it on the first install only.
debug "  ${VMNAME} (VMID ${VMID}) on ${NODE}${HANODE:+, HA ${HANODE}}, zone ${ZONE0NAME}"
install_note "  ${VMNAME} runs on ${NODE}, zone ${ZONE0NAME}: ${VMNAME}.${ZONE0NAME}.internal"
