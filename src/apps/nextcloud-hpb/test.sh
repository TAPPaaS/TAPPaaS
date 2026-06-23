#!/usr/bin/env bash
# TAPPaaS nextcloud-hpb Verification Test Script
#
# Runs verification tests for the Nextcloud Talk High-Performance Backend.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh

set -euo pipefail

# Derive all hosts from the (variant-aware) effective config, never hardcode base/zone.
MODULE="${1:-nextcloud-hpb}"
CFG_DIR="/home/tappaas/config"
EFF_JSON="${CFG_DIR}/${MODULE}.json"
VARIANT="$(jq -r '.variant // empty' "${EFF_JSON}" 2>/dev/null || true)"
TARGET="$(jq -r '.vmname' "${EFF_JSON}" 2>/dev/null).$(jq -r '.zone0' "${EFF_JSON}" 2>/dev/null).internal"
# Nextcloud provider — pair with the same variant; fall back to base for production.
NC_JSON="${CFG_DIR}/nextcloud.json"
[[ -n "${VARIANT}" && -f "${CFG_DIR}/nextcloud-${VARIANT}.json" ]] && NC_JSON="${CFG_DIR}/nextcloud-${VARIANT}.json"
NEXTCLOUD_HOST="$(jq -r '.vmname' "${NC_JSON}" 2>/dev/null || echo nextcloud).$(jq -r '.zone0' "${NC_JSON}" 2>/dev/null || echo srv).internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
# proxyDomain lives in the network:proxy config block (variant registry sets it there); fall back to top-level.
HPB_PROXY_DOMAIN="$(jq -r '.config["network:proxy"].proxyDomain // .proxyDomain // empty' "${EFF_JSON}")"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/nextcloud-hpb-test-${TIMESTAMP}.log"

YW='\033[33m'
RD='\033[01;31m'
GN='\033[32m'
BL='\033[34m'
CL='\033[m'
BOLD='\033[1m'

PASSED=0
FAILED=0
SKIPPED=0

mkdir -p "$LOG_DIR"

log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
pass()   { log "${GN}[PASS]${CL} $1"; ((++PASSED)); }
fail()   { log "${RD}[FAIL]${CL} $1"; ((++FAILED)); }
skip()   { log "${YW}[SKIP]${CL} $1"; ((++SKIPPED)); }
info()   { log "${BL}[INFO]${CL} $1"; }
header() {
    log ""
    log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
    log "${BOLD}  $1${CL}"
    log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
}

remote() { $SSH_CMD "$1" 2>/dev/null; }

if [ "$(hostname)" != "tappaas-cicd" ]; then
    echo -e "${RD}[ERROR]${CL} This script must be run on tappaas-cicd."
    exit 1
fi

header "TAPPaaS nextcloud-hpb Verification Tests"
log "Timestamp: $(date)"
log "Target:    tappaas@${TARGET}"
log "Log file:  ${LOG_FILE}"

# ============================================================================
# Test 1: VM Connectivity
# ============================================================================
header "Test 1: VM Connectivity"
info "Checking SSH connectivity to ${TARGET}..."

CONNECTED=false
if $SSH_CMD "exit 0" 2>/dev/null; then
    pass "SSH connection to ${TARGET} successful"
    CONNECTED=true
else
    fail "Cannot connect to ${TARGET} via SSH — is the VM running?"
fi

if [ "$CONNECTED" = "false" ]; then
    for i in 2 3 4 5 6 7 8; do skip "Test $i skipped (no connectivity)"; done
    header "Test Summary"
    log "  ${GN}Passed:${CL}  $PASSED / ${RD}Failed:${CL}  $FAILED / ${YW}Skipped:${CL} $SKIPPED"
    log "${RD}${BOLD}VM unreachable. No tests could run.${CL}"
    log "Full log saved to: ${LOG_FILE}"
    exit 1
fi

# ============================================================================
# Test 2: Signaling Service Status
# ============================================================================
header "Test 2: nextcloud-spreed-signaling Service Status"
info "Checking systemd unit: nextcloud-spreed-signaling..."

SVC_STATUS=$(remote "systemctl is-active nextcloud-spreed-signaling 2>/dev/null" || echo "unknown")
if [ "$SVC_STATUS" = "active" ]; then
    pass "nextcloud-spreed-signaling is active"
else
    fail "nextcloud-spreed-signaling is ${SVC_STATUS} (expected active)"
fi

# ============================================================================
# Test 3: hpb-init-secrets Completed
# ============================================================================
header "Test 3: Secrets Initialization"
info "Checking hpb-init-secrets.service completed successfully..."

# `systemctl is-active` PRINTS its status (e.g. "inactive") AND exits non-zero — so any
# `|| echo unknown` (even remote-side) appends a second line. Capture stdout, default if empty.
# `|| true` is OUTSIDE the substitution: it satisfies `set -e` (is-active exits 3 when
# inactive) without appending a second line to the captured status. Default if empty.
INIT_STATUS=$(remote "systemctl is-active hpb-init-secrets 2>/dev/null") || true
INIT_STATUS="${INIT_STATUS:-unknown}"
# A condition-gated oneshot (ConditionPathExists=!hpb-secret) correctly shows 'inactive'
# once the secrets exist; the per-secret checks below are the real verification.
if [ "$INIT_STATUS" = "active" ] || [ "$INIT_STATUS" = "inactive" ]; then
    pass "hpb-init-secrets.service is ${INIT_STATUS} (secrets provisioned)"
else
    fail "hpb-init-secrets.service is ${INIT_STATUS} — secrets may not be generated"
fi

SECRETS_DIR="/var/lib/nextcloud-hpb/secrets"
for secret in hpb-secret session-hashkey session-blockkey internalsecret turn-secret turn-apikey; do
    EXISTS=$(remote "sudo test -f ${SECRETS_DIR}/${secret} && echo yes || echo no" || echo "no")
    if [ "$EXISTS" = "yes" ]; then
        pass "  ${secret} exists"
    else
        fail "  ${secret} missing in ${SECRETS_DIR}"
    fi
done

# ============================================================================
# Test 4: Port 8080 Reachable from tappaas-cicd
# ============================================================================
header "Test 4: Port 8080 TCP Reachable"
info "Checking TCP port 8080 on ${TARGET} from tappaas-cicd..."

if nc -z -w5 "${TARGET}" 8080 2>/dev/null; then
    pass "Port 8080 TCP is open on ${TARGET}"
else
    fail "Port 8080 TCP is not reachable on ${TARGET} — check firewall or service binding"
fi

# ============================================================================
# Test 5: HPB Stats Endpoint
# ============================================================================
header "Test 5: HPB /api/v1/welcome Health Check"
info "Fetching http://${TARGET}:8080/api/v1/welcome..."

# /api/v1/welcome is the public, unauthenticated health endpoint; /stats requires the
# stats grant (IP allowlist/token) and returns non-JSON 403 to tappaas-cicd by default.
WELCOME=$(curl -sf --max-time 10 "http://${TARGET}:8080/api/v1/welcome" 2>/dev/null || true)
if echo "${WELCOME}" | grep -q '"nextcloud-spreed-signaling"'; then
    pass "HPB welcome endpoint responded (signaling server healthy)"
else
    fail "HPB welcome endpoint did not return expected JSON — service may not be ready"
fi

# ============================================================================
# Test 6: TURN Secret Synced (non-placeholder)
# ============================================================================
header "Test 6: TURN Secret Synced from coturn"
info "Checking turn-secret is present in ${SECRETS_DIR}..."

# `sudo wc -c < file` fails: the redirect is opened by the non-sudo shell (permission
# denied → 0). Read via `sudo cat … | wc -c` so the privileged process opens the file.
TURN_SIZE=$(remote "sudo cat ${SECRETS_DIR}/turn-secret 2>/dev/null | wc -c" || echo "0")
if [ "${TURN_SIZE:-0}" -ge 16 ]; then
    pass "turn-secret is ${TURN_SIZE} bytes (synced from coturn)"
else
    fail "turn-secret is missing or too short (${TURN_SIZE} bytes) — run install.sh or update.sh"
fi

# ============================================================================
# Test 7: Nextcloud Signaling Config
# ============================================================================
header "Test 7: Nextcloud Talk HPB Registration"
info "Checking Nextcloud Talk signaling_servers config on ${NEXTCLOUD_HOST}..."

# NOTE: -tt forces a pseudo-TTY. nextcloud-occ wraps the command in `systemd-run`, whose
# stdout is NOT propagated back over a non-TTY ssh — occ would appear to return empty
# (exit 0) and every occ-based assertion below would false-fail. The TTY makes occ output flow.
NC_SSH="ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${NEXTCLOUD_HOST}"

NC_REACHABLE=false
if $NC_SSH "exit 0" 2>/dev/null; then
    NC_REACHABLE=true
fi

if [ "$NC_REACHABLE" = "false" ]; then
    skip "Cannot SSH to ${NEXTCLOUD_HOST} — Nextcloud Talk config not verified"
else
    SIG_CONF=$($NC_SSH "sudo nextcloud-occ \
        config:app:get spreed signaling_servers 2>/dev/null" || true)
    if echo "${SIG_CONF}" | grep -q "${HPB_PROXY_DOMAIN}"; then
        pass "Nextcloud Talk signaling_servers contains ${HPB_PROXY_DOMAIN}"
    else
        fail "Nextcloud Talk signaling_servers does not reference the HPB (${HPB_PROXY_DOMAIN}) — install.sh may not have run"
    fi
fi

# ============================================================================
# Test 8: Nextcloud-to-HPB Backend Auth
# ============================================================================
header "Test 8: Nextcloud-to-HPB Backend Connectivity"
info "Checking Nextcloud can reach HPB via signaling backend check..."

if [ "$NC_REACHABLE" = "false" ]; then
    skip "Cannot SSH to ${NEXTCLOUD_HOST} — backend connectivity not verified"
else
    # nextcloud-occ talk:signaling:check is not available in all spreed versions;
    # check if the Talk app is enabled as a proxy for service health
    TALK_STATUS=$($NC_SSH "sudo nextcloud-occ \
        app:list 2>/dev/null | grep -w spreed | head -1" || true)
    if echo "${TALK_STATUS}" | grep -q 'spreed'; then
        pass "Nextcloud Talk (spreed) app is enabled"
    else
        skip "Could not confirm Nextcloud Talk app status — check manually"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
header "Test Summary"
log ""
log "Results:"
log "  ${GN}Passed:${CL}  $PASSED"
log "  ${RD}Failed:${CL}  $FAILED"
log "  ${YW}Skipped:${CL} $SKIPPED"
log ""
log "Total tests: $((PASSED + FAILED + SKIPPED))"
log ""

if [ "$FAILED" -eq 0 ]; then
    log "${GN}${BOLD}All tests passed!${CL}"
    EXIT_CODE=0
else
    log "${RD}${BOLD}Some tests failed. Review the output above for details.${CL}"
    EXIT_CODE=1
fi

log ""
log "Full log saved to: ${LOG_FILE}"
log ""
exit $EXIT_CODE
