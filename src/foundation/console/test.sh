#!/usr/bin/env bash
#
# console test (ADR-034 Testing).
#
#   always  the deployed config passes check-config.sh (no internet, no all);
#           the service answers /api/v1/status on the mothership's loopback, and
#           every read it caches answered at its last refresh
#   live    the published name exists: an anonymous request is sent to the
#           Authentik login (the gate), or stopped by the zone filter (a warning:
#           the mothership is not in mgmt's client view of its own route)
#
# The backend's own unit suite is tappaas-cicd/ui/test.sh.
#
# Usage: test.sh [<instance>] [--deep]
set -uo pipefail
. /home/tappaas/bin/common-install-routines.sh

PASS=0; FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

info "${BOLD}Testing console${CL}"
# The deployed config passes the module's own check: no 'internet' or 'all' in a
# zone list (check-config.sh; module-manager runs it on add and modify --set).
if [[ -f "${CONFIG_DIR}/${1:-console}.json" ]]; then
    if why="$("$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/check-config.sh" "${CONFIG_DIR}/${1:-console}.json" 2>&1)"; then
        pass "the console's zone list is mgmt and admin only (no internet, no all)"
    else
        fail "${why}"
    fi
fi
if systemctl is-active --quiet tappaas-console.service 2>/dev/null; then
    pass "tappaas-console.service is active"
    status="$(curl -fsS --max-time 15 http://127.0.0.1:9097/api/v1/status 2>/dev/null)"
    if jq -e '.data.version' <<<"${status}" >/dev/null 2>&1; then
        pass "the backend answers /api/v1/status ($(jq -r '.data.version' <<<"${status}"))"
        bad_reads="$(jq -r '[.data.reads[] | select(.error != null) | .name] | join(", ")' <<<"${status}")"
        [[ -z "${bad_reads}" ]] && pass "every read answered at its last refresh" || fail "reads that failed at their last refresh: ${bad_reads}"
    else
        fail "the backend does not answer on 127.0.0.1:9097"
    fi
else
    fail "tappaas-console.service is not active (systemctl status tappaas-console)"
fi

domain="$(jq -r '.config["network:proxy"].proxyDomain // .proxyDomain // empty' "${CONFIG_DIR}/console.json" 2>/dev/null)"
if [[ -n "${domain}" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${domain}/api/v1/me")"
    case "${code}" in
        302|401) pass "https://${domain} is behind the gate (anonymous: ${code})" ;;
        403) warn "  https://${domain}: 403 from the zone filter — the gate is not visible from here" ;;
        200) fail "https://${domain} answered an anonymous request: the gate is not in front" ;;
        *) fail "https://${domain} did not answer as a gated route (HTTP ${code})" ;;
    esac
else
    info "  no proxyDomain recorded: the route is <vmname>.<domain> (see INSTALL.md)"
fi

echo ""
info "console: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
