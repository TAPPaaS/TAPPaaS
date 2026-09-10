#!/usr/bin/env bash
#
# TAPPaaS Source-NAT Service - Install
#
# Applies the masquerade rules a module declares in snatFrom, after the
# destination zone's snat-allowed-from gate has granted them (ADR-016 D1/D2).
#
# Failure here is FATAL, deliberately. A module whose only working path runs
# through the masquerade, installed "successfully" without it, is #239: the
# charger reported installed for three weeks and was never reachable.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=snat-common.sh disable=SC1091
. "${SCRIPT_DIR}/snat-common.sh"

debug "network:snat install-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

if ! snat_requested "${MODULE_JSON}"; then
    warn "Module '${MODULE}' depends on network:snat but declares no snatFrom — nothing to do."
    debug "${GN}network:snat install-service completed for ${MODULE} (no request)${CL}"
    exit 0
fi

if [[ "$(snat_firewall_type)" == "NONE" ]]; then
    snat_report_manual "${MODULE}" "${MODULE_JSON}"
    exit 0
fi

command -v snat-manager >/dev/null 2>&1 || die "snat-manager CLI not found"

snat-manager apply-module "${MODULE}" --no-ssl-verify \
    || die "source NAT request refused for ${MODULE} — see 'snat-manager mode' and the zone's snat-allowed-from"

info "${GN}network:snat install-service completed for ${MODULE}${CL}"
