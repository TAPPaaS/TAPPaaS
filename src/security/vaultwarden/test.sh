#!/usr/bin/env bash
# TAPPaaS Module: vaultwarden — Verification Tests
#
# Runs health checks for the Vaultwarden installation, including that it is NOT
# behind the site's single sign-on (the vault keeps its own accounts).
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-vaultwarden}" 2>/dev/null || true

_VMNAME="$(get_config_value 'vmname' 'vaultwarden' 2>/dev/null || echo 'vaultwarden')"
_ZONE="$(get_config_value 'zone0' 'dmz' 2>/dev/null || echo 'dmz')"
TARGET="${_VMNAME}.${_ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/vaultwarden-test-${TIMESTAMP}.log"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' BL='\033[34m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0 SKIPPED=0
mkdir -p "$LOG_DIR"

log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
pass()   { log "${GN}[PASS]${CL} $1"; PASSED=$((PASSED + 1)); }
fail()   { log "${RD}[FAIL]${CL} $1"; FAILED=$((FAILED + 1)); }
inf()    { log "${BL}[INFO]${CL} $1"; }
header() { log ""; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; log "${BOLD}  $1${CL}"; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; }
remote() { $SSH_CMD "$1" 2>/dev/null; }

[[ "$(hostname)" == "tappaas-cicd" ]] || { echo -e "${RD}[ERROR]${CL} Run this on tappaas-cicd."; exit 1; }

header "TAPPaaS Vaultwarden Verification Tests"
log "Timestamp : $(date)"
log "Target    : tappaas@${TARGET}"
log "Log file  : ${LOG_FILE}"

inf "Checking connectivity to ${TARGET}..."
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi
inf "Connection established."

# ── Test 1: Vaultwarden service ───────────────────────────────────────────────
header "Test 1: Vaultwarden Service"
VW_STATUS=$(remote "systemctl is-active vaultwarden 2>/dev/null || echo inactive")
if [[ "${VW_STATUS}" == "active" ]]; then
    pass "vaultwarden service is active"
else
    fail "vaultwarden service is ${VW_STATUS}"
fi

# ── Test 2: HTTP endpoint ─────────────────────────────────────────────────────
header "Test 2: HTTP Endpoint"
HTTP_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8222/alive 2>/dev/null || echo 000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pass "Vaultwarden /alive returned HTTP 200"
else
    fail "Vaultwarden /alive returned HTTP ${HTTP_CODE}"
fi

# ── Test 3: Site URL ──────────────────────────────────────────────────────────
# DOMAIN is what Vaultwarden builds every link and the web vault's API base
# from; vaultwarden-site-url writes it from the published name.
header "Test 3: Site URL"
SITE_DOMAIN=$(remote "sudo grep -m1 '^DOMAIN=' /etc/secrets/vaultwarden-site.env 2>/dev/null | cut -d= -f2-" || true)
API_VAULT=$(remote "curl -s --max-time 10 http://localhost:8222/api/config" | jq -r '.environment.vault // empty' 2>/dev/null || true)
if [[ -z "${SITE_DOMAIN}" ]]; then
    fail "No DOMAIN in /etc/secrets/vaultwarden-site.env — journalctl -u vaultwarden-site-url"
elif [[ "${API_VAULT}" == "${SITE_DOMAIN%/}" ]]; then
    pass "DOMAIN is ${SITE_DOMAIN} and Vaultwarden serves it"
else
    fail "DOMAIN is ${SITE_DOMAIN} but Vaultwarden reports '${API_VAULT}' — restart vaultwarden"
fi

# ── Test 4: No single sign-on ─────────────────────────────────────────────────
# The vault must not open with the identity provider: SSO off, no SSO setting in
# any environment file the service loads, and no OIDC client left on the VM.
header "Test 4: No Single Sign-On"
SSO_SET=$(remote "for f in \$(systemctl show vaultwarden -p EnvironmentFiles --value | grep -o '/[^ ]*'); do sudo grep -H '^SSO_' \"\$f\" 2>/dev/null; done" || true)
SSO_OTHER=$(grep -vE ':SSO_ENABLED=false$' <<<"${SSO_SET}" | grep . | sed -E 's/=.*//' | tr '\n' ' ' || true)
if [[ -n "${SSO_OTHER}" ]]; then
    fail "SSO settings present: ${SSO_OTHER}— journalctl -u vaultwarden-site-url"
elif ! grep -qE ':SSO_ENABLED=false$' <<<"${SSO_SET}"; then
    fail "SSO_ENABLED=false is not pinned — journalctl -u vaultwarden-site-url"
else
    pass "SSO is off (SSO_ENABLED=false, no other SSO_* setting)"
fi
if [[ "$(remote "sudo test -e /etc/secrets/vaultwarden.env && echo yes || echo no")" == "no" ]]; then
    pass "No OIDC client on the VM"
else
    fail "/etc/secrets/vaultwarden.env (an OIDC client) is still on the VM"
fi

# ── Test 5: Resource usage ────────────────────────────────────────────────────
header "Test 5: Resource Usage"
MEM=$(remote "free -h | grep Mem" || true)
DISK=$(remote "df -h / | tail -1" || true)
inf "Memory : ${MEM}"
inf "OS disk: ${DISK}"
pass "Resource info retrieved"

# ── Summary ───────────────────────────────────────────────────────────────────
header "Test Summary"
log "  ${GN}Passed:${CL}  ${PASSED}"
log "  ${RD}Failed:${CL}  ${FAILED}"
log "  ${YW}Skipped:${CL} ${SKIPPED}"
log ""
log "Total: $((PASSED + FAILED + SKIPPED))"

if [[ "${FAILED}" -eq 0 ]]; then
    log "${GN}${BOLD}All tests passed!${CL}"
    EXIT_CODE=0
else
    log "${RD}${BOLD}Some tests failed — review output above.${CL}"
    EXIT_CODE=1
fi
log "Full log: ${LOG_FILE}"
exit "${EXIT_CODE}"
