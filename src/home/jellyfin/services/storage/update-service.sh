#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — storage service update
#
# Called by install-module.sh when a module that depends on jellyfin:storage
# is updated. Re-verifies the NFS mount on the consumer VM is still healthy
# and re-mounts if needed (idempotent).
#
# Environment set by install-module.sh:
#   MODULE_VMNAME  — name of the consuming VM
#   MODULE_ZONE    — zone of the consuming VM (defaults to srvHome)
#
# Usage: update-service.sh <consumer-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"
JELLYFIN_VMNAME="$(get_config_value 'vmname' 'jellyfin')"
JELLYFIN_ZONE="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_NFS_HOST="${JELLYFIN_VMNAME}.${JELLYFIN_ZONE}.internal"

CONSUMER_VMNAME="${MODULE_VMNAME:-${MODULE}}"
CONSUMER_ZONE="${MODULE_ZONE:-srvHome}"
CONSUMER_HOST="${CONSUMER_VMNAME}.${CONSUMER_ZONE}.internal"

if [[ -z "${CONSUMER_VMNAME}" || "${CONSUMER_VMNAME}" == "unknown" ]]; then
    warn "MODULE_VMNAME is not set. Set it to the name of the consuming VM."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

info "jellyfin:storage update-service for module: ${CONSUMER_VMNAME}"

# Check if /media-jellyfin is still mounted; re-mount if not
MOUNT=$(ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}"     "mountpoint -q /media-jellyfin && echo yes || echo no" 2>/dev/null || echo no)
if [[ "${MOUNT}" == "yes" ]]; then
    info "  ${GN}✓${CL} /media-jellyfin is mounted on ${CONSUMER_VMNAME}"
else
    warn "  /media-jellyfin not mounted on ${CONSUMER_VMNAME} — attempting remount"
    ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}"         "sudo mount /media-jellyfin 2>/dev/null || sudo mount ${JELLYFIN_NFS_HOST}:/media /media-jellyfin"       && info "  ${GN}✓${CL} /media-jellyfin remounted"       || { warn "  Remount failed — verify Jellyfin is running and NFS export is active"; exit 1; }
fi

# Verify write access is still intact
WRITE=$(ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}"     "test -w /media-jellyfin/downloads/complete && echo yes || echo no" 2>/dev/null || echo no)
if [[ "${WRITE}" == "yes" ]]; then
    info "  ${GN}✓${CL} /media-jellyfin/downloads/complete is writable"
else
    warn "  /media-jellyfin/downloads/complete is not writable — check NFS permissions"
fi
