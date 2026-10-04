#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — storage service install
#
# Mounts the Jellyfin NFS share (/media) on the DEPENDENT module's VM
# at /media-jellyfin. Called by install-module.sh when another module
# declares dependsOn: ["jellyfin:storage"].
#
# Environment set by install-module.sh:
#   MODULE_VMNAME   — name of the consuming VM (e.g. "fileservice")
#   MODULE_ZONE     — zone of the consuming VM (defaults to srvHome)
#
# Run directly for recovery:
#   MODULE_VMNAME=fileservice ./services/storage/install-service.sh

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

JELLYFIN_VMNAME="$(get_config_value 'vmname' 'jellyfin')"
JELLYFIN_ZONE="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_NFS_HOST="${JELLYFIN_VMNAME}.${JELLYFIN_ZONE}.internal"

MODULE="${1:-}"
CONSUMER_VMNAME="${MODULE_VMNAME:-${MODULE}}"
CONSUMER_ZONE="${MODULE_ZONE:-srvHome}"
CONSUMER_HOST="${CONSUMER_VMNAME}.${CONSUMER_ZONE}.internal"

if [[ -z "${CONSUMER_VMNAME}" ]]; then
    warn "MODULE_VMNAME is not set. Set it to the name of the consuming VM."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

echo ""
info "${BOLD}jellyfin: storage service install${CL}"
info "  Provider : ${JELLYFIN_NFS_HOST}:/media"
info "  Consumer : ${CONSUMER_HOST} → /media-jellyfin"

# ── Verify the NFS export is reachable from the consumer VM ──────────────────
info "  Checking NFS availability..."
NFS_OK=$(ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}" \
    "showmount -e ${JELLYFIN_NFS_HOST} 2>/dev/null | grep -q '/media' && echo yes || echo no" 2>/dev/null || echo no)
if [[ "${NFS_OK}" != "yes" ]]; then
    warn "  NFS export not visible from ${CONSUMER_HOST} — is Jellyfin running and /media mounted?"
    warn "  Verify: showmount -e ${JELLYFIN_NFS_HOST}"
    exit 1
fi
info "  ${GN}✓${CL} NFS export visible"

# ── Mount the share on the consumer VM ───────────────────────────────────────
info "  Mounting /media-jellyfin on ${CONSUMER_VMNAME}..."
ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}" \
    "sudo mkdir -p /media-jellyfin" 2>/dev/null \
  || true

# Add fstab entry if not already present (idempotent)
ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}" "
    if ! grep -qF 'media-jellyfin' /etc/fstab; then
        echo '${JELLYFIN_NFS_HOST}:/media  /media-jellyfin  nfs  defaults,nofail,x-systemd.automount,_netdev  0 0' | sudo tee -a /etc/fstab
    fi
    sudo systemctl daemon-reload
    sudo mount /media-jellyfin 2>/dev/null || sudo mount ${JELLYFIN_NFS_HOST}:/media /media-jellyfin
" 2>/dev/null \
  && info "  ${GN}✓${CL} /media-jellyfin mounted" \
  || { warn "  Could not mount — verify network connectivity from ${CONSUMER_VMNAME} to ${JELLYFIN_NFS_HOST}"; exit 1; }

# ── Verify write access to downloads/complete ────────────────────────────────
WRITE_OK=$(ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}" \
    "test -w /media-jellyfin/downloads/complete && echo yes || echo no" 2>/dev/null || echo no)
if [[ "${WRITE_OK}" == "yes" ]]; then
    info "  ${GN}✓${CL} /media-jellyfin/downloads/complete is writable"
else
    warn "  /media-jellyfin/downloads/complete is not writable — check NFS anonuid/anongid and Jellyfin user"
fi

echo ""
info "${GN}✓${CL} jellyfin storage service installed on ${CONSUMER_VMNAME}"
info "  Download path : /media-jellyfin/downloads/complete"
info "  Full media    : /media-jellyfin"
