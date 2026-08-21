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
# resolve_proxy_domain() comes from update.sh, sourced above — one implementation,
# so install and converge can never disagree about the public route.
PROXY_DOMAIN="$(resolve_proxy_domain)"

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

# ── Configure trusted domains + public URL ────────────────────────────────────
# Delegated to converge_nextcloud_domains() in update.sh. It is called again here
# because update.sh is sourced BEFORE the VM exists, where it defers. This call
# runs once the VM is up. The converge verifies its own write.
converge_nextcloud_domains || warn "  Domain config failed — installation continues; see the error above."

echo ""
info "${GN}✓${CL} nextcloud installation completed successfully."
echo ""
info "  Admin login : https://${PROXY_DOMAIN}/login?direct=1"
info "  Username    : admin"
info "  Password    : ${ADMIN_PASS:-<see /var/lib/nextcloud/admin-pass on VM>}"
