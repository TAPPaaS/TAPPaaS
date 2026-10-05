#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — mediaserver service update
#
# Called by install-module.sh when a module that depends on jellyfin:mediaserver
# is updated. Verifies the media disk is still mounted and Jellyfin is still
# serving its API — no disk-side changes are needed during a consumer update.
#
# Usage: update-service.sh <consumer-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"
VMNAME="$(get_config_value 'vmname' 'jellyfin')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

info "jellyfin:mediaserver update-service for module: ${MODULE}"

# Verify /media is still mounted
MOUNT=$(ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" "mountpoint -q /media && echo yes || echo no" 2>/dev/null)
if [[ "${MOUNT}" == "yes" ]]; then
    info "  ${GN}✓${CL} /media is mounted on ${JELLYFIN_HOST}"
else
    warn "  /media is not mounted on ${JELLYFIN_HOST} — media disk may need reattaching"
fi

# Verify Jellyfin API is up
HTTP_CODE=$(ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}"     "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8096/health 2>/dev/null || echo 000")
if [[ "${HTTP_CODE}" =~ ^(200|301|302)$ ]]; then
    info "  ${GN}✓${CL} Jellyfin API is reachable (HTTP ${HTTP_CODE})"
else
    warn "  Jellyfin API returned HTTP ${HTTP_CODE} — service may be starting up"
fi
