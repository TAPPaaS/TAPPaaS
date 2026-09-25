#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service - Update
#
# Verifies coturn is still reachable after a dependent module updates.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"

# Resolve coturn's config environment-awarely (same as install-service.sh): an
# environment consumer pairs with the same-environment provider; base may not
# exist. Was .variant until that field was retired (#438).
CONSUMER_ENV=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
COTURN_JSON="${CONFIG_DIR}/$(resolve_provider_module coturn "${CONSUMER_ENV}").json"
readonly COTURN_JSON

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:turn update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "  ${GN}✓${CL} coturn STUN/TURN is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    warn "  coturn not responding on port 3478 — TURN relay may be unavailable"
fi

# ── Converge the TURN host fact into the consumer (services/turn/fields.json) ──
# Re-derived on every update, so a coturn publicDomain added or changed after
# the consumer's install reaches the consumer's .nix on the next rebuild.
# shellcheck source=turn-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/turn-common.sh"
coturn_stamp_turn_host "${CONSUMER_JSON}" "$(coturn_turn_host "${COTURN_JSON}")" "$(coturn_turn_host_internal "${COTURN_JSON}")"
coturn_allow_peer "${COTURN_JSON}" "${CONSUMER_JSON}"
