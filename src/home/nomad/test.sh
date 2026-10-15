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

# 4. Reachable at its internal address, as the client networks reach it.
[[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${TARGET}:8080/api/health")" == "200" ]] \
    && pass "http://${TARGET}:8080 answers" || fail "http://${TARGET}:8080 does not answer"
[[ "$(remote "sudo cat /var/lib/project-nomad/url 2>/dev/null")" == "http://${TARGET}:8080" ]] \
    && pass "NOMAD's URL is http://${TARGET}:8080, so its app links open at ${TARGET}:<port>" \
    || fail "NOMAD's URL is not http://${TARGET}:8080 (update.sh sets it)"

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
