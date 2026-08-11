#!/usr/bin/env bash
#
# TAPPaaS coturn VM Service - Update
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
# Resolve coturn's config environment-awarely: a consumer deployed into an
# environment pairs with the same-environment provider; fall back to the shared
# config otherwise. Was .variant until that field was retired (#438).
CONSUMER_ENV=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
COTURN_JSON="${CONFIG_DIR}/$(resolve_provider_module coturn "${CONSUMER_ENV}").json"
readonly COTURN_JSON

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:vm update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "  ${GN}✓${CL} coturn is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    warn "  coturn not responding on port 3478 — Talk audio/video calls may be unavailable"
fi
