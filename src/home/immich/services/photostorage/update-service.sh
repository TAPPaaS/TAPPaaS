#!/usr/bin/env bash
# TAPPaaS Module: immich — photostorage service update
#
# Called by install-module.sh when a module that depends on immich:photostorage
# is updated. Verifies the data disk is still mounted and Immich is still
# serving its API — no disk-side changes are needed during a consumer update.
#
# Usage: update-service.sh <consumer-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"
VMNAME="$(get_config_value 'vmname' 'immich')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

info "immich:photostorage update-service for module: ${MODULE}"

# Verify /var/lib/immich is still mounted
MOUNT=$(ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" "mountpoint -q /var/lib/immich && echo yes || echo no" 2>/dev/null)
if [[ "${MOUNT}" == "yes" ]]; then
    info "  ${GN}✓${CL} /var/lib/immich is mounted on ${IMMICH_HOST}"
else
    warn "  /var/lib/immich is not mounted on ${IMMICH_HOST} — data disk may need reattaching"
fi

# Verify Immich API is up
PING=$(ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "curl -s --max-time 10 http://localhost:2283/api/server/ping 2>/dev/null || echo unreachable")
if [[ "${PING}" == *pong* ]]; then
    info "  ${GN}✓${CL} Immich API is reachable (ping → pong)"
else
    warn "  Immich API did not answer ping — service may be starting up"
fi
