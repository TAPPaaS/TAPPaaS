#!/usr/bin/env bash
#
# TAPPaaS Nextcloud Service - Update
#
# Verifies that Nextcloud is still reachable after a dependent module updates.
# No Nextcloud-side changes are needed during a dependent module update — the
# consuming module's own update.sh (e.g. euro-office) handles any connector
# reconfiguration (JWT sync, URL settings).
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"

readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve Nextcloud's config variant-awarely: a consumer deployed as a variant
# pairs with the same-variant provider; fall back to the base for production.
VARIANT=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    VARIANT=$(jq -r '.variant // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
if [[ -n "${VARIANT}" && -f "${CONFIG_DIR}/nextcloud-${VARIANT}.json" ]]; then
    readonly NEXTCLOUD_JSON="${CONFIG_DIR}/nextcloud-${VARIANT}.json"
else
    readonly NEXTCLOUD_JSON="${CONFIG_DIR}/nextcloud.json"
fi

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

info "nextcloud:fileservice update-service for module: ${MODULE}"

if curl -sf --max-time 10 "${INTERNAL_URL}/status.php" | grep -q '"installed":true'; then
    info "  ${GN}✓${CL} Nextcloud is reachable at ${INTERNAL_URL}"
else
    warn "  Nextcloud not responding at ${INTERNAL_URL}/status.php — connector sync may fail"
fi
