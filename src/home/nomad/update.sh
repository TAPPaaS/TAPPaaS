#!/usr/bin/env bash
# TAPPaaS Module: nomad (Project N.O.M.A.D.) — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# on every install and update, before this runs. This gives NOMAD the one value
# the VM cannot work out for itself: the address its users reach it at,
# http://<vmname>.<zone>.internal:8080 (its URL). NOMAD is not published outside
# the site; the client networks reach it, and the apps it links to on their own
# ports, through the module's ingress rules.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-nomad}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
NOMAD_HOST="${VMNAME}.${ZONE0NAME}.internal"
URL="http://${NOMAD_HOST}:8080"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${NOMAD_HOST}" "$@"; }

echo ""
info "${BOLD}nomad: the Command Center at ${URL}${CL}"

if [[ "$(vm "sudo cat /var/lib/project-nomad/url 2>/dev/null" || true)" != "${URL}" ]]; then
    vm "sudo install -d -m 0700 /var/lib/project-nomad && echo '${URL}' | sudo tee /var/lib/project-nomad/url >/dev/null && sudo systemctl restart project-nomad.service" \
        && info "  ${GN}✓${CL} URL set" \
        || warn "  could not set the URL on ${NOMAD_HOST}"
fi

for _i in $(seq 1 60); do
    vm "curl -sf --max-time 5 http://localhost:8080/api/health >/dev/null" 2>/dev/null && break
    [[ ${_i} -eq 60 ]] && { warn "  the Command Center did not answer within 5 minutes — see journalctl -u project-nomad on the VM"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} Command Center answers"

echo ""
info "${BOLD}Update complete${CL}"
info "  From the home network: ${URL} — the apps open at ${NOMAD_HOST}:<port>"
