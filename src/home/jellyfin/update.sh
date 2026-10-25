#!/usr/bin/env bash
# TAPPaaS Module: jellyfin -- Update
#
# Makes sure the library folders exist under /media. Sourced by install.sh, so
# a first install gets them too.
#
# The NixOS configuration is NOT built here. templates:nixos (update-os.sh)
# builds and applies jellyfin.nix on every install and update -- against the
# release's pinned nixpkgs, built on the mothership (#774). It is listed after
# storage:nfs in jellyfin.json, so the share mount storage:nfs writes into
# /etc/nixos/tappaas-nfs.nix is part of that build. A rebuild here would build
# again against the VM's own channel and could undo a release move.
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

debug "  jellyfin: library folders on ${JELLYFIN_HOST}"

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
      && info "  ${GN}✓${CL} jellyfin library folders present on ${where}" \
      || warn "  could not create the library folders on /media -- check the share's grant (rw)"
fi

debug "  ${VMNAME} (VMID ${VMID}) on ${NODE}, zone ${ZONE0NAME}"
install_note "  ${VMNAME} runs on ${NODE}, zone ${ZONE0NAME}: ${JELLYFIN_HOST}"
