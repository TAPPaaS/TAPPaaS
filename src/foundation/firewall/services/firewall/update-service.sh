#!/usr/bin/env bash
#
# TAPPaaS Firewall Service - Update
#
# Reconciles per-module firewall rules on OPNsense for a consuming module.
# Diffs the module's current ports/ingress/egress declarations against the
# live OPNsense state, applies any changes, and prunes rules that are no
# longer declared -- all in a single savepoint-wrapped transaction.
#
# When firewallType is "NONE", prints a manual configuration reminder.
#
# Usage: update-service.sh <module-name>
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
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:firewall update-service for module: ${BL}${MODULE}${CL}"

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

# -- Check firewallType -----------------------------------------------

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "Ensure your firewall rules for module '${MODULE}' are up to date:"
    warn "  ${BL}${INGRESS_COUNT}${CL} ingress and ${BL}${EGRESS_COUNT}${CL} egress rule(s) declared in ${MODULE}.json"
    info "${GN}firewall:firewall update-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# -- OPNsense: validate firewall-rules-manager ------------------------

if ! command -v firewall-rules-manager &>/dev/null; then
    die "firewall-rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# -- Reconcile rules --------------------------------------------------
#
# reconcile is idempotent: it upserts declared rules and prunes any rule
# that exists in OPNsense (with the "TAPPaaS: <module>" prefix) but is no
# longer present in module.json. Re-running on unchanged input is a no-op.

info "  Reconciling firewall rules..."
firewall-rules-manager reconcile "${MODULE}" \
    --config-dir "${CONFIG_DIR}" \
    --no-ssl-verify || die "Failed to reconcile firewall rules for ${MODULE}"

info "${GN}firewall:firewall update-service completed for ${MODULE}${CL}"
