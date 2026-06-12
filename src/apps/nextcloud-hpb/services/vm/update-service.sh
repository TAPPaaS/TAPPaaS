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
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve HPB's config variant-awarely: a consumer deployed as a variant pairs
# with the same-variant provider; fall back to the base for production.
VARIANT=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    VARIANT=$(jq -r '.variant // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
if [[ -n "${VARIANT}" && -f "${CONFIG_DIR}/nextcloud-hpb-${VARIANT}.json" ]]; then
    readonly HPB_JSON="${CONFIG_DIR}/nextcloud-hpb-${VARIANT}.json"
else
    readonly HPB_JSON="${CONFIG_DIR}/nextcloud-hpb.json"
fi

VMNAME=$(jq -r '.vmname' "${HPB_JSON}")
ZONE=$(jq -r '.zone0' "${HPB_JSON}")

info "nextcloud-hpb:vm update-service for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 8080 2>/dev/null; then
    info "  ${GN}✓${CL} nextcloud-hpb is reachable at ${VMNAME}.${ZONE}.internal:8080"
else
    warn "  nextcloud-hpb not responding on port 8080 — Nextcloud Talk signaling may be unavailable"
fi
