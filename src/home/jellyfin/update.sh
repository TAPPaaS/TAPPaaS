#!/usr/bin/env bash
# TAPPaaS Module: jellyfin -- Update
#
# Pushes the current jellyfin.nix to the running VM and applies it.
# Sourced by install.sh so the same config apply runs on first install too.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-jellyfin}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'allocate')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "${BOLD}Deploying jellyfin.nix to ${JELLYFIN_HOST}${CL}"

# ── Stage jellyfin.nix, generating the /media mount for share mode ──────────
# The block between the media-mount markers in jellyfin.nix is managed here:
# with mediaStorage=share it is replaced by the NFS/CIFS mount declared in
# jellyfin.json (mediaShareHost/mediaShareExport/mediaShareType/
# mediaShareOptions). In allocate/attached modes the file is deployed as-is.
STAGED_NIX="$(mktemp /tmp/jellyfin.nix.XXXXXX)"
trap 'rm -f "${STAGED_NIX}"' EXIT
cp "${SCRIPT_DIR}/jellyfin.nix" "${STAGED_NIX}"

if [[ "${MEDIA_MODE}" == "share" ]]; then
    SHARE_HOST="$(get_config_value 'mediaShareHost' '')"
    SHARE_EXPORT="$(get_config_value 'mediaShareExport' '')"
    SHARE_TYPE="$(get_config_value 'mediaShareType' 'nfs')"
    SHARE_OPTS="$(get_config_value 'mediaShareOptions' '')"

    [[ -n "${SHARE_HOST}" && -n "${SHARE_EXPORT}" ]] \
      || die "mediaStorage=share requires mediaShareHost and mediaShareExport in jellyfin.json (see INSTALL.md → Path 3)."
    case "${SHARE_TYPE}" in
        nfs)
            SHARE_DEVICE="${SHARE_HOST}:${SHARE_EXPORT}"
            [[ -n "${SHARE_OPTS}" ]] || SHARE_OPTS="nofail,noatime,x-systemd.automount,_netdev"
            ;;
        cifs)
            SHARE_DEVICE="//${SHARE_HOST}/${SHARE_EXPORT#/}"
            # CIFS needs credentials; there is no safe default — require them.
            [[ -n "${SHARE_OPTS}" ]] \
              || die "mediaShareType=cifs requires mediaShareOptions (including a credentials= file on the VM) in jellyfin.json."
            ;;
        *)  die "Unknown mediaShareType '${SHARE_TYPE}' — must be nfs or cifs." ;;
    esac
    # Nix options list: "a,b,c" → [ "a" "b" "c" ]
    SHARE_OPTS_NIX="[ $(echo "${SHARE_OPTS}" | tr ',' '\n' | sed 's/^/"/; s/$/"/' | tr '\n' ' ')]"

    awk -v dev="${SHARE_DEVICE}" -v fst="${SHARE_TYPE}" -v opts="${SHARE_OPTS_NIX}" '
        /# BEGIN media-mount/ {
            print
            print "  fileSystems.\"/media\" = {"
            print "    device  = \"" dev "\";"
            print "    fsType  = \"" fst "\";"
            print "    options = " opts ";"
            print "  };"
            skip=1; next
        }
        /# END media-mount/ { skip=0 }
        !skip
    ' "${SCRIPT_DIR}/jellyfin.nix" > "${STAGED_NIX}"
    grep -q "device  = \"${SHARE_DEVICE}\"" "${STAGED_NIX}" \
      || die "Failed to generate the share mount into jellyfin.nix (media-mount markers missing?)."
    info "  ${GN}✓${CL} /media mount generated: ${SHARE_TYPE} ${SHARE_DEVICE}"
fi

# SCP to /tmp first (tappaas user cannot write /etc/nixos directly),
# then sudo install into place -- mirrors what update-os.sh does.
scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${STAGED_NIX}" \
    "tappaas@${JELLYFIN_HOST}:/tmp/jellyfin.nix" \
  && info "  ${GN}✓${CL} jellyfin.nix staged to /tmp" \
  || { warn "  Could not push jellyfin.nix -- is ${JELLYFIN_HOST} reachable?"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
    "sudo install -m 0644 /tmp/jellyfin.nix /etc/nixos/jellyfin.nix && rm -f /tmp/jellyfin.nix" \
  && info "  ${GN}✓${CL} jellyfin.nix installed to /etc/nixos/" \
  || { warn "  Could not install jellyfin.nix to /etc/nixos/"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" \
    "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/jellyfin.nix 2>&1 | tail -5" \
  && info "  ${GN}✓${CL} nixos-rebuild switch completed" \
  || { warn "  nixos-rebuild reported errors -- check journalctl on ${JELLYFIN_HOST}"; exit 1; }

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
