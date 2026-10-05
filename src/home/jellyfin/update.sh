#!/usr/bin/env bash
# TAPPaaS Module: jellyfin -- Update
#
# Pushes the current jellyfin.nix to the running VM and applies it, then makes
# sure the library folders exist on the media share. Sourced by install.sh so
# the same config apply runs on first install too.
#
# /media is an NFS share (pvehost:nfs): pvehost:nfs's install/update service
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

# ── Library folders on the media share ───────────────────────────────────────
# Created here, not by tmpfiles: every write to the share is squashed to the
# export's owner, so a tmpfiles chown to jellyfin would fail. `ls` triggers the
# automount; only an NFS mount gets folders — never the bare local /media.
if ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
    "ls /media >/dev/null 2>&1; findmnt -n -t nfs,nfs4 /media >/dev/null"; then
    ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
        "sudo -u jellyfin mkdir -p /media/Movies /media/TV /media/Music /media/Photos /media/Audiobooks" \
      && info "  ${GN}✓${CL} library folders present on the media share" \
      || warn "  could not create the library folders on /media -- check the export's grant (rw)"
else
    warn "  /media is not mounted -- is the node serving its 'media' export? (update-module.sh <node>)"
fi

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
