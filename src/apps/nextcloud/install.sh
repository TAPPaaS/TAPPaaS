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
    # Inline upsert (the toolbox has no upsert_secret): drop any existing line, append fresh.
    mkdir -p "$(dirname "${SECRETS_FILE}")"
    { grep -v '^NEXTCLOUD_ADMIN_PASS=' "${SECRETS_FILE}" 2>/dev/null || true; \
      printf 'NEXTCLOUD_ADMIN_PASS=%s\n' "${ADMIN_PASS}"; } > "${SECRETS_FILE}.tmp"
    mv "${SECRETS_FILE}.tmp" "${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
    info "  Admin credentials saved to ${SECRETS_FILE}"
else
    warn "  Could not read admin password from ${NEXTCLOUD_HOST} — check manually:"
    warn "    ssh tappaas@${NEXTCLOUD_HOST} 'sudo cat /var/lib/nextcloud/admin-pass'"
fi

# ── Configure trusted domains + public URL via occ ─────────────────────────────
# Call nextcloud-occ DIRECTLY (it self-switches to the nextcloud user). Do NOT wrap it in
# `systemd-run -p User=nextcloud` — nextcloud-occ runs systemd-run internally, so wrapping it
# nests systemd-run as a non-root user, which polkit denies during/after activation (exit 1).
# Nix no longer pins trusted_domains, so these occ values persist (no override.config.php shadow).
# Index 0 = hostName (auto-added by NixOS); we append the internal FQDN, the environment/public
# domain, and localhost.
if [[ -n "${PROXY_DOMAIN}" ]]; then
    info "${BOLD}Configuring trusted domains + public URL…${CL}"
    if occ_out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "tappaas@${NEXTCLOUD_HOST}" \
        "sudo nextcloud-occ config:system:set trusted_domains 1 --value='${NEXTCLOUD_HOST}' && \
         sudo nextcloud-occ config:system:set trusted_domains 2 --value='${PROXY_DOMAIN}' && \
         sudo nextcloud-occ config:system:set trusted_domains 3 --value='localhost' && \
         sudo nextcloud-occ config:system:set overwrite.cli.url --value='https://${PROXY_DOMAIN}' && \
         sudo nextcloud-occ config:system:set overwriteprotocol --value='https'" 2>&1)
    then
        info "  ${GN}✓${CL} Trusted domains + public URL configured (https://${PROXY_DOMAIN})"
    else
        warn "  Domain config failed (deploy continues) — occ output:"
        warn "    ${occ_out}"
    fi
fi

echo ""
info "${GN}✓${CL} nextcloud installation completed successfully."
echo ""
info "  Admin login : https://${PROXY_DOMAIN}/login?direct=1"
info "  Username    : admin"
info "  Password    : ${ADMIN_PASS:-<see /var/lib/nextcloud/admin-pass on VM>}"
