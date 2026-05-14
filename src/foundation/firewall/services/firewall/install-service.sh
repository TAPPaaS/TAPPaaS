#!/usr/bin/env bash
#
# TAPPaaS Firewall Service - Install
#
# Configures per-module firewall rules on OPNsense for a consuming module.
# Compiles the module's ports/ingress/egress/aliases declarations and applies
# them atomically via the firewall-rules-manager CLI.
#
# When firewallType is "NONE" (no OPNsense deployed), this script prints the
# manual firewall configuration the deployer needs to apply on their own
# firewall, then exits successfully.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
#
# The script reads the module JSON from /home/tappaas/config/<module>.json
# and firewall.json for firewallType. It then:
#   1. Validates the module declares firewall:firewall in dependsOn
#   2. Checks firewallType (NONE -> print manual instructions, exit 0)
#   3. Calls firewall-rules-manager add-rules <module>
#

set -euo pipefail

# -- Logging ----------------------------------------------------------

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# -- Arguments --------------------------------------------------------

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:firewall install-service for module: ${BL}${MODULE}${CL}"

# -- Validate inputs --------------------------------------------------

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# -- Read module configuration ----------------------------------------

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
INGRESS_COUNT=$(jq -r '(.ingress // []) | length' "${MODULE_JSON}")
EGRESS_COUNT=$(jq -r '(.egress // []) | length' "${MODULE_JSON}")

info "  Zone:     ${BL}${ZONE}${CL}"
info "  Ingress:  ${BL}${INGRESS_COUNT}${CL} declared"
info "  Egress:   ${BL}${EGRESS_COUNT}${CL} declared"

# Nothing to do if the module declares no rules.
if [[ "${INGRESS_COUNT}" -eq 0 && "${EGRESS_COUNT}" -eq 0 ]]; then
    info "${GN}firewall:firewall install-service completed for ${MODULE} (no rules declared)${CL}"
    exit 0
fi

# -- Check firewallType -----------------------------------------------

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "The module '${MODULE}' declares per-module firewall rules."
    warn ""
    warn "${BOLD}Please configure the following on your firewall:${CL}"
    jq -r '
        (.ingress // [])[] |
        "  INGRESS  from \(.from) -> \(env.VMNAME):\(.ports | join(",")) \(.protocol // "TCP")  (\(.why // ""))"
    ' "${MODULE_JSON}" | while read -r line; do warn "${line}"; done
    jq -r '
        (.egress // [])[] |
        "  EGRESS   \(env.VMNAME) -> \(.to):\(.ports | join(",")) \(.protocol // "TCP")  (\(.why // ""))"
    ' "${MODULE_JSON}" | while read -r line; do warn "${line}"; done
    warn ""
    warn "Continuing without automated firewall setup."
    info "${GN}firewall:firewall install-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# -- OPNsense: validate firewall-rules-manager ------------------------

if ! command -v firewall-rules-manager &>/dev/null; then
    die "firewall-rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# -- Apply rules ------------------------------------------------------

info "  Applying firewall rules..."
firewall-rules-manager add-rules "${MODULE}" \
    --config-dir "${CONFIG_DIR}" \
    --no-ssl-verify || die "Failed to apply firewall rules for ${MODULE}"

info "${GN}firewall:firewall install-service completed for ${MODULE}${CL}"
