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

# Resolve coturn's config variant-awarely (same as install-service.sh): a variant
# consumer pairs with the same-variant provider; base may not exist.
VARIANT=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    VARIANT=$(jq -r '.variant // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
if [[ -n "${VARIANT}" && -f "${CONFIG_DIR}/coturn-${VARIANT}.json" ]]; then
    readonly COTURN_JSON="${CONFIG_DIR}/coturn-${VARIANT}.json"
else
    readonly COTURN_JSON="${CONFIG_DIR}/coturn.json"
fi

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:turn update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "  ${GN}✓${CL} coturn STUN/TURN is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    warn "  coturn not responding on port 3478 — TURN relay may be unavailable"
fi
