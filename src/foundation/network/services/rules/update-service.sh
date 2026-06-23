#!/usr/bin/env bash
#
# TAPPaaS Rules Service - Update
#
# Reconciles a consumer module's firewall rules against the desired state in
# its module.json: applies new/changed rules and removes orphans (rules with
# the `tappaas-module:<vmname>:` prefix that no longer appear in module.json).
#
# When firewallType is "NONE", prints manual configuration instructions and
# exits 0.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi

info "network:rules update-service for module: ${BL}${MODULE}${CL}"

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if ! command -v rules-manager &>/dev/null; then
    die "rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

rules-manager reconcile "${MODULE}" \
    --firewall-type "${FIREWALL_TYPE}" \
    --no-ssl-verify \
    || die "rules-manager reconcile failed for ${MODULE}"

info "${GN}network:rules update-service completed for ${MODULE}${CL}"
