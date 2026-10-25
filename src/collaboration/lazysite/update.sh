#!/usr/bin/env bash
# TAPPaaS Module: lazysite — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# before this runs; forgejo:repo has written the repository's address and the
# deploy key. This pulls the latest commit now (instead of within the minute)
# and waits for the home page.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-lazysite}")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${HOST}" "$@"; }

debug "  lazysite: bringing the site's latest commit on ${HOST}"
pulled=""
if vm "sudo systemctl start lazysite-pull.service" 2>/dev/null; then
    pulled="$(vm "sudo journalctl -u lazysite-pull -n 20 --no-pager -o cat | grep -E '^lazysite-pull:' | tail -1" 2>/dev/null || true)"
    debug "  ${pulled:-lazysite-pull ran}"
else
    warn "  lazysite-pull failed — see journalctl -u lazysite-pull on the VM (repository and deploy key come from forgejo:repo)"
fi

for _i in $(seq 1 24); do
    code="$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/" 2>/dev/null || true)"
    [[ "${code}" == "200" ]] && break
    [[ ${_i} -eq 24 ]] && { warn "  the home page answers ${code:-nothing} after 2 minutes — see journalctl -u lazysite -u nginx on the VM"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} lazysite is at the repository's latest commit and its home page answers"

DOMAIN="$(vm "jq -r 'select(.proxyPublished != false) | .proxyDomain // empty' /etc/nixos/lazysite.json" 2>/dev/null || true)"
REPO="$(vm "sudo sed -n 's/^REPO_WEB_URL=//p' /etc/secrets/forgejo-repo.env" 2>/dev/null || true)"
if [[ -n "${DOMAIN}" ]]; then SITE="https://${DOMAIN}"; else SITE="http://${HOST}:8080 (not published)"; fi
install_note "  Site      : ${SITE}"
install_note "  Pages in  : ${REPO:-the Forgejo repository websites/${VMNAME}} — commit, and the site follows within a minute"
