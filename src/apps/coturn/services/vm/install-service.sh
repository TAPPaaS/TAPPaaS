#!/usr/bin/env bash
#
# TAPPaaS coturn VM Service - Install
#
# Verifies the coturn VM is reachable before dependent modules install.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve coturn's config variant-awarely: a consumer deployed as a variant pairs
# with the same-variant provider; fall back to the base for production.
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

info "coturn:vm install-service — verifying coturn is reachable for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "${GN}✓${CL} coturn is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    die "coturn is not responding on port 3478 — ensure the coturn module is fully installed"
fi
