#!/usr/bin/env bash
#
# forgejo — install
#
# Thin wrapper: all configuration logic lives in update.sh.
# VM creation is handled by cluster:vm install-service.sh (declared via
# "cluster:vm" in dependsOn) and is invoked by install-module.sh before
# this script runs.
#
# Usage: install.sh <vmname>
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-forgejo}"

# Run the update logic — install = first update
. "$(dirname "${BASH_SOURCE[0]}")/update.sh" "${1:-forgejo}"

# ── Break-glass admin (#282) ─────────────────────────────────────────
# Accounts come from Authentik, and local sign-up is off. One local admin is
# still needed: for the site before SSO works, and as the way back in when
# Authentik is down. Created only on an instance with no users; the generated
# password is printed ONCE — store it. Sign in at /user/login (local form).
ADMIN_USER="tappaas-admin"
ADMIN_MAIL="tappaas-admin@${VMNAME}.internal"   # not a real mailbox: a local account
users="$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo forgejo-admin admin user list 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "")"
if [[ "${users}" == "0" ]]; then
    out="$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo forgejo-admin admin user create --admin --username ${ADMIN_USER} --email ${ADMIN_MAIL} --random-password --must-change-password=false" 2>&1)" \
        || die "could not create the break-glass admin: ${out}"
    pw="$(sed -n "s/.*generated random password is '\(.*\)'.*/\1/p" <<<"${out}")"
    echo ""
    info "${BOLD}Break-glass admin${CL} (local login at /user/login — store this, it is shown once):"
    info "  user: ${ADMIN_USER}   password: ${pw:-see output above}"
elif [[ -z "${users}" ]]; then
    warn "could not list Forgejo users — create a local admin by hand: sudo forgejo-admin admin user create --admin ..."
else
    debug "  Forgejo already has users — no break-glass admin created"
fi

echo ""
info "${GN}✓${CL} Forgejo installation completed successfully."
info "  Next: run post-install steps from INSTALL.md §Post-install"
