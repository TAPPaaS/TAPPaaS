#!/usr/bin/env bash
#
# TAPPaaS nextcloud-hpb VM Service - Update
#
# Verifies the HPB is still reachable after a dependent module updates.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"
readonly HPB_JSON="/home/tappaas/config/nextcloud-hpb.json"

VMNAME=$(jq -r '.vmname' "${HPB_JSON}")
ZONE=$(jq -r '.zone0' "${HPB_JSON}")

info "nextcloud-hpb:vm update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 8080 2>/dev/null; then
    info "  ${GN}✓${CL} nextcloud-hpb is reachable at ${VMNAME}.${ZONE}.internal:8080"
else
    warn "  nextcloud-hpb not responding on port 8080 — Nextcloud Talk signaling may be unavailable"
fi
