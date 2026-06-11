#!/usr/bin/env bash
# TAPPaaS Module: nextcloud — Installation
#
# Nextcloud with PostgreSQL and Redis
#
# Creates the nextcloud VM in Proxmox and applies initial configuration.
# It assumes that you are in the install directory.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh nextcloud

. /home/tappaas/bin/common-install-routines.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-nextcloud}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' '')"
if [[ -z "${PROXY_DOMAIN}" ]]; then
    _TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' \
        "/home/tappaas/config/configuration.json" 2>/dev/null)
    PROXY_DOMAIN="${VMNAME}.${_TAPPAAS_DOMAIN}"
fi

# ── Copy admin password to local secrets file ─────────────────────────────────
echo ""
info "${BOLD}Reading Nextcloud admin credentials…${CL}"

NEXTCLOUD_HOST="${VMNAME}.${ZONE0NAME}.internal"
SECRETS_FILE="/home/tappaas/secrets/${VMNAME}.env"

ADMIN_PASS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
    "tappaas@${NEXTCLOUD_HOST}" \
    "sudo cat /var/lib/nextcloud/admin-pass 2>/dev/null" || true)

if [[ -n "${ADMIN_PASS}" ]]; then
    upsert_secret "${SECRETS_FILE}" "NEXTCLOUD_ADMIN_PASS" "${ADMIN_PASS}"
    info "  Admin credentials saved to ${SECRETS_FILE}"
else
    warn "  Could not read admin password from ${NEXTCLOUD_HOST} — check manually:"
    warn "    ssh tappaas@${NEXTCLOUD_HOST} 'sudo cat /var/lib/nextcloud/admin-pass'"
fi

# ── Configure public domain via occ (not in Nix — works like openwebui) ────────
if [[ -n "${PROXY_DOMAIN}" ]]; then
    info "${BOLD}Configuring public domain…${CL}"
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "tappaas@${NEXTCLOUD_HOST}" \
        "sudo systemd-run --no-ask-password -p User=nextcloud -p Type=oneshot \
          /run/current-system/sw/bin/nextcloud-occ config:system:set trusted_domains 0 --value='${PROXY_DOMAIN}' && \
         sudo systemd-run --no-ask-password -p User=nextcloud -p Type=oneshot \
          /run/current-system/sw/bin/nextcloud-occ config:system:set trusted_domains 1 --value='${VMNAME}' && \
         sudo systemd-run --no-ask-password -p User=nextcloud -p Type=oneshot \
          /run/current-system/sw/bin/nextcloud-occ config:system:set overwrite.cli.url --value='https://${PROXY_DOMAIN}' && \
         sudo systemd-run --no-ask-password -p User=nextcloud -p Type=oneshot \
          /run/current-system/sw/bin/nextcloud-occ config:system:set overwriteprotocol --value='https'" \
        2>/dev/null && \
        info "  ${GN}✓${CL} Domain configured: https://${PROXY_DOMAIN}" || \
        warn "  Could not configure domain — run occ manually after setup"
fi

echo ""
info "${GN}✓${CL} nextcloud installation completed successfully."
echo ""
info "  Admin login : https://${PROXY_DOMAIN}/login?direct=1"
info "  Username    : admin"
info "  Password    : ${ADMIN_PASS:-<see /var/lib/nextcloud/admin-pass on VM>}"
