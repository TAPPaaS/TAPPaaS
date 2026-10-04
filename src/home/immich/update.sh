#!/usr/bin/env bash
# TAPPaaS Module: immich -- Update
#
# Pushes the current immich.nix to the running VM and applies it.
# Sourced by install.sh so the same config apply runs on first install too.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-immich}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "${BOLD}Deploying immich.nix to ${IMMICH_HOST}${CL}"

# SCP to /tmp first (tappaas user cannot write /etc/nixos directly),
# then sudo install into place -- mirrors what update-os.sh does.
scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${SCRIPT_DIR}/immich.nix" \
    "tappaas@${IMMICH_HOST}:/tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix staged to /tmp" \
  || { warn "  Could not push immich.nix -- is ${IMMICH_HOST} reachable?"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "sudo install -m 0644 /tmp/immich.nix /etc/nixos/immich.nix && rm -f /tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix installed to /etc/nixos/" \
  || { warn "  Could not install immich.nix to /etc/nixos/"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "set -o pipefail; sudo nixos-rebuild switch -I nixos-config=/etc/nixos/immich.nix 2>&1 | tail -5" \
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
PROXY_DOMAIN="$(module_public_domain "${VMNAME}" "$(get_config_value 'environment' '')" "${JSON}")"
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
