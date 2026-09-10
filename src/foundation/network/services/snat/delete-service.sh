#!/usr/bin/env bash
#
# TAPPaaS Source-NAT Service - Delete
#
# Removes every source-NAT rule the module owns, by description prefix rather
# than by its current declaration — a module whose snatFrom was emptied before
# it was deleted must still be cleaned up.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=snat-common.sh disable=SC1091
. "${SCRIPT_DIR}/snat-common.sh"

debug "network:snat delete-service for module: ${BL}${MODULE}${CL}"

if [[ "$(snat_firewall_type)" == "NONE" ]]; then
    debug "  firewallType=NONE — nothing to remove"
    exit 0
fi

if ! command -v snat-manager >/dev/null 2>&1; then
    warn "  snat-manager CLI not found — cannot remove source-NAT rules for ${MODULE}"
    exit 0
fi

# A failed cleanup warns rather than dies: a module delete that cannot finish
# because of a leftover firewall rule leaves a worse mess than the rule does.
snat-manager delete-module "${MODULE}" --no-ssl-verify \
    || warn "  Could not remove source-NAT rules for ${MODULE}"

info "${GN}network:snat delete-service completed for ${MODULE}${CL}"
