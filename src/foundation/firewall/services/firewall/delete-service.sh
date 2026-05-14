#!/usr/bin/env bash
#
# TAPPaaS Firewall Service - Delete
#
# Removes all per-module firewall rules and module-local aliases that were
# created on OPNsense for a consuming module. Identifies them by the
# "TAPPaaS: <module>" description prefix via the firewall-rules-manager CLI.
#
# When firewallType is "NONE", prints a reminder to clean up manual config.
#
# Usage: delete-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
#

set -euo pipefail

# -- Logging ----------------------------------------------------------

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# -- Arguments --------------------------------------------------------

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:firewall delete-service for module: ${BL}${MODULE}${CL}"

# -- Check firewallType -----------------------------------------------

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "Remember to remove the firewall rules for module '${MODULE}' from your firewall."
    info "${GN}firewall:firewall delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

# -- OPNsense: validate firewall-rules-manager ------------------------

if ! command -v firewall-rules-manager &>/dev/null; then
    die "firewall-rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# -- Note on missing module JSON --------------------------------------
#
# remove-rules tolerates a missing module.json: it falls back to cleaning
# up by the "TAPPaaS: <module>" description prefix. This matters when a
# module is being torn down and its config has already been removed.

if [[ ! -f "${MODULE_JSON}" ]]; then
    warn "Module config not found: ${MODULE_JSON} -- cleaning up by description prefix"
fi

# -- Remove rules -----------------------------------------------------

info "  Removing firewall rules..."
firewall-rules-manager remove-rules "${MODULE}" \
    --config-dir "${CONFIG_DIR}" \
    --no-ssl-verify || warn "Could not fully remove firewall rules for ${MODULE}"

info "${GN}firewall:firewall delete-service completed for ${MODULE}${CL}"
