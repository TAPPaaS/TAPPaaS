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

# 4. The Command Center only through the gate (it starts any container: root on the VM).
[[ "$(remote "systemctl is-active nomad-fence")" == "active" ]] && pass "nomad-fence is active" \
    || fail "nomad-fence is not active (journalctl -u nomad-fence on the VM)"
_fence="$(remote "sudo iptables -S DOCKER-USER")"
grep -q -- "--ctorigdstport 8080 -j REJECT" <<<"${_fence}" && grep -q -- "-j DROP" <<<"${_fence}" \
    && pass "DOCKER-USER: 8080 only from Caddy, no published port from a zone neighbour" \
    || fail "DOCKER-USER does not fence 8080 and the zone's neighbours: ${_fence:-empty}"
_direct="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${TARGET}:8080/api/health")"
[[ "${_direct}" == "000" ]] && pass "http://${TARGET}:8080 is refused from here (not Caddy)" \
    || fail "http://${TARGET}:8080 answered ${_direct} from tappaas-cicd — the Command Center is reachable around the gate"
_url="$(remote "sudo sed -n 's/^NOMAD_URL=//p' /var/lib/project-nomad/.env")"
[[ "${_url}" == https://* ]] && pass "the Command Center's URL is the gated name ${_url}" \
    || fail "the Command Center's URL is ${_url:-unset}, not the gated https name"
if [[ "${_url}" == https://* ]]; then
    _gate="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "${_url}/")"
    [[ "${_gate}" == "302 "* ]] \
        && pass "${_url} asks for the Authentik sign-in" \
        || fail "${_url} does not redirect to the sign-in (got: ${_gate})"
fi

# 5. The Command Center's tiles open the apps at the internal address.
_links="$(remote "sudo nomad-links check" | tail -1)"
[[ "${_links}" == "0" ]] && pass "every installed app's tile opens at ${TARGET}:<port>" \
    || fail "${_links:-?} installed app(s) without an internal URL (nomad-links on the VM)"

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
