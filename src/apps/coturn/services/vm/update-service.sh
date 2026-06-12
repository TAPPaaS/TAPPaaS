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
readonly COTURN_JSON="${CONFIG_DIR}/coturn.json"

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:vm update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "  ${GN}✓${CL} coturn is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    warn "  coturn not responding on port 3478 — Talk audio/video calls may be unavailable"
fi
