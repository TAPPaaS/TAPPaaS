#!/usr/bin/env bash
#
# TAPPaaS Rules Service - Delete
#
# Removes all firewall rules and aliases owned by a module (every OPNsense
# rule whose description begins with `tappaas-module:<vmname>:`, and any
# `tappaas-module-<vmname>` FQDN alias that no other module still references).
#
# When firewallType is "NONE", logs a no-op and exits 0.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:rules delete-service for module: ${BL}${MODULE}${CL}"

if [[ ! -f "${MODULE_JSON}" ]]; then
    warn "Module config not found: ${MODULE_JSON} (continuing — rules may still be removed by description prefix)"
fi

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "firewallType=NONE — please manually remove any firewall rules for ${MODULE} on your firewall."
    info "${GN}firewall:rules delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

if ! command -v rules-manager &>/dev/null; then
    die "rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

rules-manager remove-rules "${MODULE}" \
    --firewall-type "${FIREWALL_TYPE}" \
    --no-ssl-verify \
    || die "rules-manager remove-rules failed for ${MODULE}"

info "${GN}firewall:rules delete-service completed for ${MODULE}${CL}"
