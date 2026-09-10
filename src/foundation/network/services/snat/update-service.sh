#!/usr/bin/env bash
#
# TAPPaaS Source-NAT Service - Update
#
# Re-asserts the module's declaration against the firewall. This is the hook
# that makes an EDITED module JSON take effect, and it is symmetric on
# purpose: apply-module adds a rule for a zone added to snatFrom AND removes
# the rule for a zone taken out of it.
#
# A dropped zone whose rule lingers is drift that reads as success — the same
# shape as #239 — so the removal half is not optional. It also picks up a
# change to the zone gate: a zone revoked in snat-allowed-from turns the next
# update into a refusal rather than a silent, still-live rule.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=snat-common.sh disable=SC1091
. "${SCRIPT_DIR}/snat-common.sh"

debug "network:snat update-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

if [[ "$(snat_firewall_type)" == "NONE" ]]; then
    snat_requested "${MODULE_JSON}" && snat_report_manual "${MODULE}" "${MODULE_JSON}"
    exit 0
fi

command -v snat-manager >/dev/null 2>&1 || die "snat-manager CLI not found"

# Unconditional, even when snatFrom is now empty: that is exactly the case
# where rules must be REMOVED, and skipping it would strand them.
snat-manager apply-module "${MODULE}" --no-ssl-verify \
    || die "source NAT reconcile failed for ${MODULE}"

info "${GN}network:snat update-service completed for ${MODULE}${CL}"
