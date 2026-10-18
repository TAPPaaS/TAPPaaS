#!/usr/bin/env bash
# TAPPaaS Module: karakeep — Verification Tests
#
# Run from tappaas-cicd as the tappaas user. Usage: ./test.sh [vmname]

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-karakeep}" 2>/dev/null || true

VMNAME="$(get_config_value 'vmname' 'karakeep' 2>/dev/null || echo karakeep)"
ZONE0NAME="$(get_config_value 'zone0' 'srv' 2>/dev/null || echo srv)"
TARGET="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
remote() { ssh "${SSH_OPTS[@]}" "tappaas@${TARGET}" "$@" 2>/dev/null; }

PASSED=0; FAILED=0
pass() { info "  ${GN}✓${CL} $1"; PASSED=$((PASSED + 1)); }
fail() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }
skipt() { info "  - $1 (skipped)"; }

info "${BOLD}Karakeep on ${TARGET}${CL}"
remote "exit 0" || { fail "cannot reach tappaas@${TARGET}"; echo "Results: ${PASSED} passed, ${FAILED} failed"; exit 1; }

# 1. The stack runs.
[[ "$(remote "systemctl is-active docker")" == "active" ]] && pass "docker is active" || fail "docker is not active"
[[ "$(remote "systemctl is-active karakeep")" == "active" ]] && pass "karakeep.service is active" \
    || fail "karakeep.service is not active (journalctl -u karakeep on the VM)"
_running="$(remote "sudo docker ps --format '{{.Names}}'" | sort | paste -sd, -)"
for c in karakeep_web karakeep_chrome karakeep_meilisearch; do
    [[ ",${_running}," == *",${c},"* ]] && pass "container ${c} runs" || fail "container ${c} is not running"
done

# 2. It answers, on pinned images, and Meilisearch holds only its own key.
[[ "$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:3000/api/health")" == "200" ]] \
    && pass "/api/health answers 200" || fail "/api/health does not answer 200"
_images="$(remote "sudo docker ps --format '{{.Image}}'" | grep -E 'karakeep|meilisearch' | paste -sd' ' -)"
[[ -n "${_images}" && "${_images}" != *":latest"* && "${_images}" != *":release"* ]] \
    && pass "pinned images: ${_images}" || fail "an image is unpinned or missing: ${_images:-none}"
[[ "$(remote "sudo grep -vc '^MEILI_MASTER_KEY=' /run/karakeep/meili.env")" == "0" ]] \
    && pass "Meilisearch gets its master key and no other secret" || fail "Meilisearch's environment holds more than its key"

# 3. Sign in with Authentik, through the published name.
PUB="$(remote "jq -r 'select(.proxyPublished != false) | .proxyDomain // empty' /etc/nixos/karakeep.json")"
FW4="$(getent ahostsv4 firewall.mgmt.internal | awk '{print $1; exit}')"
if [[ "$(remote "test -s /etc/secrets/karakeep.env && echo yes")" != "yes" ]]; then
    skipt "no sign-in configuration (/etc/secrets/karakeep.env) — identity:identity has not run"
else
    [[ "$(remote "sudo grep -c '^DISABLE_PASSWORD_AUTH=true' /run/karakeep/env")" == "1" ]] \
        && pass "Karakeep signs in with Authentik only (no local passwords)" || fail "the Authentik sign-in is not in Karakeep's environment"
    if [[ -n "${PUB}" && -n "${FW4}" ]]; then
        # NextAuth always lists its Credentials provider; with DISABLE_PASSWORD_AUTH
        # (checked above) Karakeep refuses a password sign-in and a sign-up on the
        # server, so what matters here is that Authentik is offered.
        _prov="$(curl -s --max-time 10 --resolve "${PUB}:443:${FW4}" "https://${PUB}/api/auth/providers" | jq -r '[.[].name] | join(",")' 2>/dev/null)"
        [[ ",${_prov}," == *",Authentik,"* ]] && pass "https://${PUB} offers Sign in with Authentik" \
            || fail "https://${PUB}/api/auth/providers lists '${_prov:-nothing}', expected Authentik"
    else
        skipt "not published — sign-in checked on the VM only"
    fi
fi

# 4. AI tagging through LiteLLM, when the site has the AI stack.
if [[ "$(remote "test -s /etc/secrets/litellm-svckey.env && echo yes")" != "yes" ]]; then
    skipt "no LiteLLM key (/etc/secrets/litellm-svckey.env) — the site has no AI stack, tagging is off"
else
    _model="$(remote "sudo sed -n 's/^INFERENCE_TEXT_MODEL=//p' /run/karakeep/env" | tail -1)"
    [[ -n "${_model}" ]] && pass "AI tagging through LiteLLM with ${_model}" \
        || fail "a LiteLLM key is on the VM but no model was chosen (LiteLLM's /models answered nothing)"
fi

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
