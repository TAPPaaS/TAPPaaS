#!/usr/bin/env bash
# TAPPaaS Module: nomad (Project N.O.M.A.D.) — Verification Tests
#
# Run from tappaas-cicd as the tappaas user. Usage: ./test.sh [vmname]

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-nomad}" 2>/dev/null || true

VMNAME="$(get_config_value 'vmname' 'nomad' 2>/dev/null || echo nomad)"
ZONE0NAME="$(get_config_value 'zone0' 'srv' 2>/dev/null || echo srv)"
TARGET="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
remote() { ssh "${SSH_OPTS[@]}" "tappaas@${TARGET}" "$@" 2>/dev/null; }

PASSED=0; FAILED=0
pass() { info "  ${GN}✓${CL} $1"; PASSED=$((PASSED + 1)); }
fail() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }

info "${BOLD}Project N.O.M.A.D. on ${TARGET}${CL}"

remote "exit 0" || { fail "cannot reach tappaas@${TARGET}"; echo "Results: ${PASSED} passed, ${FAILED} failed"; exit 1; }

# 1. The stack runs.
[[ "$(remote "systemctl is-active docker")" == "active" ]] && pass "docker is active" || fail "docker is not active"
[[ "$(remote "systemctl is-active project-nomad")" == "active" ]] && pass "project-nomad.service is active" \
    || fail "project-nomad.service is not active (journalctl -u project-nomad on the VM)"
_running="$(remote "sudo docker ps --format '{{.Names}}'" | sort | paste -sd, -)"
for c in nomad_admin nomad_mysql nomad_redis nomad_disk_collector; do
    [[ ",${_running}," == *",${c},"* ]] && pass "container ${c} runs" || fail "container ${c} is not running"
done

# 2. The Command Center answers, and its secrets were generated.
[[ "$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/api/health")" == "200" ]] \
    && pass "Command Center /api/health answers 200" || fail "Command Center /api/health does not answer 200"
remote "sudo grep -q '^NOMAD_APP_KEY=.\{32,\}' /var/lib/project-nomad/.env" \
    && pass "secrets generated on the VM (/var/lib/project-nomad/.env)" || fail "no generated secrets on the VM"

# 3. The images are the pinned ones, never :latest.
_images="$(remote "sudo docker ps --format '{{.Image}}'" | grep -E 'crosstalk-solutions' | paste -sd' ' -)"
[[ -n "${_images}" && "${_images}" != *":latest"* ]] && pass "pinned images: ${_images}" || fail "an image is unpinned or missing: ${_images:-none}"

# 4. Behind the sign-in: through the proxy, an anonymous request is sent to identity.
_env="$(get_config_value 'environment' '' 2>/dev/null || true)"
_domain="$(module_public_domain "${VMNAME}" "${_env}" "$(read_module_config "${VMNAME}" 2>/dev/null || echo '{}')" 2>/dev/null || true)"
if [[ -n "${_domain}" ]]; then
    _fw="$(getent ahostsv4 firewall.mgmt.internal | awk '{print $1; exit}')"
    _loc="$(curl -ks -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 \
        --resolve "${_domain}:443:${_fw}" "https://${_domain}/")"
    case "${_loc}" in
        30[12378]\ *outpost.goauthentik.io*|30[12378]\ *identity*) pass "https://${_domain}/ redirects to the sign-in (${_loc%% *})" ;;
        *) fail "https://${_domain}/ is not behind the sign-in (got ${_loc})" ;;
    esac
else
    info "  ${YW}⊘${CL} not published (no public name) — the sign-in gate is not tested"
fi

# 5. App links point at the VM, not at the public name.
_bad="$(remote "sudo bash -c '. /var/lib/project-nomad/.env; docker exec -i nomad_mysql mysql -N -unomad_user -p\"\${NOMAD_DB_PASSWORD}\" nomad -e \"SELECT COUNT(*) FROM services WHERE ui_location REGEXP \\\"^(https?:)?[0-9]+\\\$\\\" AND (custom_url IS NULL OR custom_url = \\\"\\\")\" 2>/dev/null'")"
[[ "${_bad}" == "0" ]] && pass "every app opens at ${TARGET}:<port>" || fail "${_bad:-?} app(s) still open at the public name (update.sh sets them)"

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
