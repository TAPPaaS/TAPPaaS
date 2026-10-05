#!/usr/bin/env bash
# TAPPaaS Module: jellyfin -- Update
#
# Pushes the current jellyfin.nix to the running VM and applies it, then makes
# sure the library folders exist on the media share. Sourced by install.sh so
# the same config apply runs on first install too.
#
# /media is an NFS share (storage:nfs): storage:nfs's install/update service
# writes /etc/nixos/tappaas-nfs.nix before this runs, and the rebuild below is
# what applies it.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-jellyfin}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "${BOLD}Deploying jellyfin.nix to ${JELLYFIN_HOST}${CL}"

# SCP to /tmp first (tappaas user cannot write /etc/nixos directly),
# then sudo install into place -- mirrors what update-os.sh does.
scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${SCRIPT_DIR}/jellyfin.nix" \
    "tappaas@${JELLYFIN_HOST}:/tmp/jellyfin.nix" \
  && info "  ${GN}✓${CL} jellyfin.nix staged to /tmp" \
  || { warn "  Could not push jellyfin.nix -- is ${JELLYFIN_HOST} reachable?"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
    "sudo install -m 0644 /tmp/jellyfin.nix /etc/nixos/jellyfin.nix && rm -f /tmp/jellyfin.nix" \
  && info "  ${GN}✓${CL} jellyfin.nix installed to /etc/nixos/" \
  || { warn "  Could not install jellyfin.nix to /etc/nixos/"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
    "set -o pipefail; sudo nixos-rebuild switch -I nixos-config=/etc/nixos/jellyfin.nix 2>&1 | tail -5" \
  && info "  ${GN}✓${CL} nixos-rebuild switch completed" \
  || { warn "  nixos-rebuild reported errors -- check journalctl on ${JELLYFIN_HOST}"; exit 1; }

# ── Library folders under /media ──────────────────────────────────────────────
# /media is the share "media" (subdir jellyfin) when a server declares it, and a
# directory on this VM's own disk while the mount is pending (ADR-029 v0.8) —
# the folders are created either way, so Jellyfin is usable from day one. When
# the share arrives later, the update migrates what is here into it (rebootOk).
# Created here, not by tmpfiles: on the share every write is squashed to its
# owner, so a tmpfiles chown to jellyfin would fail. `ls` triggers the automount.
if ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" "findmnt -n --fstab /media >/dev/null" \
   && ! ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" "ls /media >/dev/null 2>&1; findmnt -n -t nfs,nfs4 /media >/dev/null"; then
    # Declared as the share but not mounted: never write the folders under it.
    warn "  /media should be the media share but is not mounted -- is its server up? (update-module.sh <node>)"
else
    where="the media share"
    ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" "findmnt -n -t nfs,nfs4 /media >/dev/null" \
        || where="this VM's disk (media share pending -- declare 'media' for a real library)"
    ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
        "sudo install -d -o jellyfin -g jellyfin /media 2>/dev/null || true; sudo -u jellyfin mkdir -p /media/Movies /media/TV /media/Music /media/Photos /media/Audiobooks" \
      && info "  ${GN}✓${CL} library folders present on ${where}" \
      || warn "  could not create the library folders on /media -- check the share's grant (rw)"
fi

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
