#!/usr/bin/env bash
# TAPPaaS Module: nomad (Project N.O.M.A.D.) — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# on every install and update, before this runs; the proxy route and the
# Authentik gate are network:proxy's and identity:accessControl's. The
# Command Center's URL is the gated public name, which nomad.nix reads from the
# module config deployed beside it — the URL file an earlier version wrote
# (http://<vmname>.<zone>.internal:8080) is removed here.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-nomad}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
NOMAD_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${NOMAD_HOST}" "$@"; }

echo ""
info "${BOLD}nomad: the Command Center behind the identity gate${CL}"

if vm "sudo test -e /var/lib/project-nomad/url"; then
    vm "sudo rm -f /var/lib/project-nomad/url && sudo systemctl restart project-nomad.service" \
        && info "  ${GN}✓${CL} the old internal URL is gone; the Command Center now names its gated address" \
        || warn "  could not remove /var/lib/project-nomad/url on ${NOMAD_HOST}"
fi

for _i in $(seq 1 60); do
    vm "curl -sf --max-time 5 http://localhost:8080/api/health >/dev/null" 2>/dev/null && break
    [[ ${_i} -eq 60 ]] && { warn "  the Command Center did not answer within 5 minutes — see journalctl -u project-nomad on the VM"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} Command Center answers"
_url="$(vm "sudo sed -n 's/^NOMAD_URL=//p' /var/lib/project-nomad/.env" 2>/dev/null || true)"
vm "sudo systemctl start nomad-links.service" >/dev/null 2>&1 || true

echo ""
info "${BOLD}Update complete${CL}"
info "  The Command Center: ${_url:-https://<proxyDomain>} — signed in, members of admin"
info "  The apps it installs: http://${NOMAD_HOST}:<port>, from the client networks"
