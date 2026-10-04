#!/usr/bin/env bash
# TAPPaaS Module: immich -- Update
#
# Pushes the current immich.nix to the running VM and applies it.
# Sourced by install.sh so the same config apply runs on first install too.
#
# Two blocks in immich.nix are managed here before deployment:
#   media-mount — with mediaStorage=share it is replaced by the NFS/CIFS
#                 mount declared in immich.json (mediaShareHost/Export/
#                 Type/Options). In allocate/attached modes deployed as-is.
#   ml-config   — machine-learning.enable is set from "machineLearning"
#                 in immich.json (default true).
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-immich}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'allocate')"
ML_ENABLED="$(get_config_value 'machineLearning' 'true')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "${BOLD}Deploying immich.nix to ${IMMICH_HOST}${CL}"

# ── Stage immich.nix, applying the managed marker blocks ─────────────────────
STAGED_NIX="$(mktemp /tmp/immich.nix.XXXXXX)"
trap 'rm -f "${STAGED_NIX}"' EXIT
cp "${SCRIPT_DIR}/immich.nix" "${STAGED_NIX}"

# media-mount block: generated for share mode, deployed as-is otherwise
if [[ "${MEDIA_MODE}" == "share" ]]; then
    SHARE_HOST="$(get_config_value 'mediaShareHost' '')"
    SHARE_EXPORT="$(get_config_value 'mediaShareExport' '')"
    SHARE_TYPE="$(get_config_value 'mediaShareType' 'nfs')"
    SHARE_OPTS="$(get_config_value 'mediaShareOptions' '')"

    [[ -n "${SHARE_HOST}" && -n "${SHARE_EXPORT}" ]] \
      || die "mediaStorage=share requires mediaShareHost and mediaShareExport in immich.json (see INSTALL.md → Path 3)."
    case "${SHARE_TYPE}" in
        nfs)
            SHARE_DEVICE="${SHARE_HOST}:${SHARE_EXPORT}"
            [[ -n "${SHARE_OPTS}" ]] || SHARE_OPTS="nofail,noatime,x-systemd.automount,_netdev"
            ;;
        cifs)
            SHARE_DEVICE="//${SHARE_HOST}/${SHARE_EXPORT#/}"
            # CIFS needs credentials; there is no safe default — require them.
            [[ -n "${SHARE_OPTS}" ]] \
              || die "mediaShareType=cifs requires mediaShareOptions (including a credentials= file on the VM) in immich.json."
            ;;
        *)  die "Unknown mediaShareType '${SHARE_TYPE}' — must be nfs or cifs." ;;
    esac
    # Nix options list: "a,b,c" → [ "a" "b" "c" ]
    SHARE_OPTS_NIX="[ $(echo "${SHARE_OPTS}" | tr ',' '\n' | sed 's/^/"/; s/$/"/' | tr '\n' ' ')]"

    awk -v dev="${SHARE_DEVICE}" -v fst="${SHARE_TYPE}" -v opts="${SHARE_OPTS_NIX}" '
        /# BEGIN media-mount/ {
            print
            print "  fileSystems.\"/var/lib/immich\" = {"
            print "    device  = \"" dev "\";"
            print "    fsType  = \"" fst "\";"
            print "    options = " opts ";"
            print "  };"
            skip=1; next
        }
        /# END media-mount/ { skip=0 }
        !skip
    ' "${SCRIPT_DIR}/immich.nix" > "${STAGED_NIX}"
    grep -q "device  = \"${SHARE_DEVICE}\"" "${STAGED_NIX}" \
      || die "Failed to generate the share mount into immich.nix (media-mount markers missing?)."
    info "  ${GN}✓${CL} /var/lib/immich mount generated: ${SHARE_TYPE} ${SHARE_DEVICE}"
fi

# ml-config block: machine-learning.enable from "machineLearning" (default true)
case "${ML_ENABLED}" in
    true|false) ;;
    *) die "\"machineLearning\" in immich.json must be true or false (got: ${ML_ENABLED})." ;;
esac
ML_STAGED="$(mktemp /tmp/immich.nix.ml.XXXXXX)"
awk -v ml="${ML_ENABLED}" '
    /# BEGIN ml-config/ {
        print
        print "    machine-learning.enable = " ml ";"
        skip=1; next
    }
    /# END ml-config/ { skip=0 }
    !skip
' "${STAGED_NIX}" > "${ML_STAGED}"
mv "${ML_STAGED}" "${STAGED_NIX}"
grep -q "machine-learning.enable = ${ML_ENABLED};" "${STAGED_NIX}" \
  || die "Failed to set machine-learning.enable in immich.nix (ml-config markers missing?)."
info "  ${GN}✓${CL} machine-learning.enable = ${ML_ENABLED}"

# SCP to /tmp first (tappaas user cannot write /etc/nixos directly),
# then sudo install into place -- mirrors what update-os.sh does.
scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${STAGED_NIX}" \
    "tappaas@${IMMICH_HOST}:/tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix staged to /tmp" \
  || { warn "  Could not push immich.nix -- is ${IMMICH_HOST} reachable?"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "sudo install -m 0644 /tmp/immich.nix /etc/nixos/immich.nix && rm -f /tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix installed to /etc/nixos/" \
  || { warn "  Could not install immich.nix to /etc/nixos/"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/immich.nix 2>&1 | tail -5" \
  && info "  ${GN}✓${CL} nixos-rebuild switch completed" \
  || { warn "  nixos-rebuild reported errors -- check journalctl on ${IMMICH_HOST}"; exit 1; }

# ── Tell immich-configure-oidc.service this VM's own public URL ──────────────
# The mobile app's OAuth callback (app.immich:///oauth-callback, a custom URI
# scheme) is never registered anywhere directly -- Immich ships a built-in
# route, /api/oauth/mobile-redirect, that forwards to it, and that route is
# just a normal https path (see immich.json's identity.oidcRedirectPaths,
# handled entirely by the stock, unmodified identity:identity mechanism --
# no special-casing needed for it at all). Immich's own oauth.mobileRedirectUri
# setting needs to be told that same URL, though, and immich-configure-oidc's
# script only sees /etc/secrets/immich.env (OIDC_CLIENT_ID/SECRET/DISCOVERY_URI,
# written by identity:identity) -- it has no way to know this module's own
# public domain otherwise. Co-manage a fourth key into the same file: identity's
# own merge-write already preserves any non-OIDC_ line (documented at
# install-service.sh Step 5b, "co-managed keys" -- the same mechanism
# euro-office/nextcloud connectors already rely on), so this is safe to run on
# every update alongside it.
PROXY_DOMAIN="$(get_config_value 'proxyDomain' '')"
if [[ -z "${PROXY_DOMAIN}" ]]; then
    _DOMAIN=$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)
    [[ -n "${_DOMAIN}" ]] && PROXY_DOMAIN="${VMNAME}.${_DOMAIN}"
fi
if [[ -n "${PROXY_DOMAIN}" ]]; then
    if ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
        "sudo sh -c 'umask 077; t=\$(mktemp /etc/secrets/.immich.XXXXXX) || exit 1; \
           { [ -f /etc/secrets/immich.env ] && grep -v \"^IMMICH_PUBLIC_URL=\" /etc/secrets/immich.env; \
             echo \"IMMICH_PUBLIC_URL=https://${PROXY_DOMAIN}\"; } > \"\$t\" && \
           chmod 600 \"\$t\" && mv -f \"\$t\" /etc/secrets/immich.env'"; then
        info "  ${GN}✓${CL} IMMICH_PUBLIC_URL set for immich-configure-oidc.service"
        # nixos-rebuild switch above already started the service once -- before
        # this key existed, since it's wantedBy=multi-user.target and this write
        # necessarily happens after activation. Nothing else re-triggers it (a
        # oneshot already "active (exited)" isn't restarted by a later rebuild
        # unless the unit itself changed), so without this it would silently
        # stay web-only until the next reboot. Re-run it now.
        ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
            "sudo systemctl restart immich-configure-oidc.service" \
          && info "  ${GN}✓${CL} immich-configure-oidc.service re-applied with the mobile override" \
          || warn "  could not restart immich-configure-oidc.service -- it will retry on next boot"
    else
        warn "  Could not write IMMICH_PUBLIC_URL to ${IMMICH_HOST} -- the mobile app's"
        warn "  OAuth redirect override will not be set (web login is unaffected)."
    fi
else
    warn "  No domain configured -- skipping IMMICH_PUBLIC_URL (mobile OAuth override)"
fi

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
