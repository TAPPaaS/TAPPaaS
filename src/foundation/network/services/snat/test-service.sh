#!/usr/bin/env bash
#
# TAPPaaS Source-NAT Service - Test
#
# Asserts the module's declared masquerade rules are live AND ENFORCED.
#
# Enforcement is the whole point. OPNsense accepts a source-NAT rule into
# config and then excludes it from the generated ruleset while the firewall's
# outbound mode is 'automatic', so a test that only greps for the rule's
# presence passes on a masquerade that carries no traffic. That is exactly
# what #239 did for three weeks, and what #623 reported from the other side.
#
# Usage: test-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: test-service.sh <module-name>"
    exit 1
fi

readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=snat-common.sh disable=SC1091
. "${SCRIPT_DIR}/snat-common.sh"

info "network:snat test-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

if ! snat_requested "${MODULE_JSON}"; then
    info "  No snatFrom declared — nothing to verify."
    info "${GN}network:snat test-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

if [[ "$(snat_firewall_type)" == "NONE" ]]; then
    warn "  firewallType=NONE — source NAT cannot be verified"
    exit 0
fi

command -v snat-manager >/dev/null 2>&1 || die "snat-manager CLI not found"

if snat-manager verify-module "${MODULE}" --no-ssl-verify; then
    info "${GN}network:snat test-service passed for ${MODULE}${CL}"
    exit 0
fi

error "${RD}network:snat test-service detected drift for ${MODULE}${CL}"
exit 1
