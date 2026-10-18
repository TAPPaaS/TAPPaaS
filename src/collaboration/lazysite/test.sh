#!/usr/bin/env bash
# TAPPaaS Module: lazysite — Verification Tests
#
# Run from tappaas-cicd as the tappaas user. Usage: ./test.sh [vmname]

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-lazysite}" 2>/dev/null || true

VMNAME="$(get_config_value 'vmname' 'lazysite' 2>/dev/null || echo lazysite)"
ZONE0NAME="$(get_config_value 'zone0' 'dmz' 2>/dev/null || echo dmz)"
TARGET="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
remote() { ssh "${SSH_OPTS[@]}" "tappaas@${TARGET}" "$@" 2>/dev/null; }

PASSED=0; FAILED=0
pass() { info "  ${GN}✓${CL} $1"; PASSED=$((PASSED + 1)); }
fail() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }
skipt() { info "  - $1 (skipped)"; }

info "${BOLD}lazysite on ${TARGET}${CL}"
remote "exit 0" || { fail "cannot reach tappaas@${TARGET}"; echo "Results: ${PASSED} passed, ${FAILED} failed"; exit 1; }

# 1. The renderer, the web server and the content pull run; the renderer is not root.
for u in lazysite.socket lazysite.service nginx.service lazysite-pull.timer; do
    [[ "$(remote "systemctl is-active ${u}")" == "active" ]] && pass "${u} is active" || fail "${u} is not active"
done
[[ "$(remote "systemctl show -p User --value lazysite.service")" == "lazysite" ]] \
    && pass "the renderer runs as lazysite" || fail "the renderer does not run as the lazysite user"

# 2. The site shows the repository's latest commit.
if [[ "$(remote "sudo test -s /etc/secrets/forgejo-repo.env && echo yes")" != "yes" ]]; then
    fail "no repository (/etc/secrets/forgejo-repo.env) — forgejo:repo has not run"
else
    _head="$(remote 'sudo bash -c '"'"'. /etc/secrets/forgejo-repo.env; GIT_SSH_COMMAND="ssh -i /etc/secrets/forgejo-repo.key -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/secrets/forgejo-repo.known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes" git ls-remote "$REPO_SSH_URL" "refs/heads/${REPO_BRANCH:-main}" | cut -f1'"'"'')"
    _deployed="$(remote "cat /var/lib/lazysite/deployed")"
    [[ -n "${_head}" && "${_head}" == "${_deployed}" ]] && pass "the site is at the repository's latest commit (${_head:0:8})" \
        || fail "the site is at ${_deployed:-nothing}, the repository at ${_head:-unreadable}"
fi

# 3. Pages render; sources are not handed out.
get() { remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $* http://localhost:8080$_p"; }
_p=/; [[ "$(get)" == "200" ]] && pass "the home page answers 200" || fail "the home page does not answer 200"
_home="$(remote "curl -s --max-time 10 http://localhost:8080/")"
[[ "${_home}" == *"<html"* ]] && pass "the home page is rendered HTML" || fail "the home page is not HTML"
_src="$(remote "curl -s --max-time 10 http://localhost:8080/index.md")"
[[ "${_src}" != "---"* ]] && pass "/index.md is not handed out as Markdown" || fail "/index.md hands out the page source"

# 4. Only the renderer is reachable: no manager, sign-in, WebDAV, CGI or engine files.
for _p in /cgi-bin/lazysite-auth.pl /cgi-bin/lazysite-manager-api.pl /manager/ /dav/ /lazysite/lazysite.conf /.git/config /.env; do
    _c="$(get)"
    [[ "${_c}" == "404" || "${_c}" == "403" ]] && pass "${_p} is closed (${_c})" || fail "${_p} answers ${_c}"
done
_spoof="$(remote "curl -s --max-time 10 -H 'X-Remote-User: admin' -H 'X-Remote-Groups: admins' http://localhost:8080/")"
[[ "${_spoof}" != *"/manager"* ]] && pass "an X-Remote-User header signs no one in" || fail "an X-Remote-User header reaches lazysite (the manager bar shows)"

# 5. Visitors' addresses, not the firewall's, reach the renderer.
[[ "$(remote "grep -c '^set_real_ip_from' /run/lazysite-nginx/realip.conf")" -ge 1 ]] \
    && pass "nginx takes the visitor's address from the firewall's X-Forwarded-For" || fail "no set_real_ip_from in /run/lazysite-nginx/realip.conf"

# 6. Published: through the firewall's Caddy.
PUB="$(remote "jq -r 'select(.proxyPublished != false) | .proxyDomain // empty' /etc/nixos/lazysite.json")"
FW4="$(getent ahostsv4 firewall.mgmt.internal | awk '{print $1; exit}')"
if [[ -n "${PUB}" && -n "${FW4}" ]]; then
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${PUB}:443:${FW4}" "https://${PUB}/")"
    [[ "${_c}" == "200" ]] && pass "https://${PUB}/ answers 200" || fail "https://${PUB}/ answers ${_c}"
else
    skipt "not published — checked on the VM only"
fi

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
