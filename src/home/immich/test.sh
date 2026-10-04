#!/usr/bin/env bash
# TAPPaaS Module: immich — Verification Tests
#
# Runs health checks for the Immich installation.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-immich}" 2>/dev/null || true

_VMNAME="$(get_config_value 'vmname' 'immich' 2>/dev/null || echo 'immich')"
_ZONE="$(get_config_value 'zone0' 'srvHome' 2>/dev/null || echo 'srvHome')"
_ML="$(get_config_value 'machineLearning' 'true' 2>/dev/null || echo 'true')"
TARGET="${_VMNAME}.${_ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/immich-test-${TIMESTAMP}.log"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' BL='\033[34m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0 SKIPPED=0
mkdir -p "$LOG_DIR"

log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
pass()   { log "${GN}[PASS]${CL} $1"; PASSED=$((PASSED+1)); }
fail()   { log "${RD}[FAIL]${CL} $1"; FAILED=$((FAILED+1)); }
skip()   { log "${YW}[SKIP]${CL} $1"; SKIPPED=$((SKIPPED+1)); }
inf()    { log "${BL}[INFO]${CL} $1"; }
header() { log ""; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; log "${BOLD}  $1${CL}"; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; }
remote() { $SSH_CMD "$1" 2>/dev/null; }

[[ "$(hostname)" == "tappaas-cicd" ]] || { echo -e "${RD}[ERROR]${CL} Run this on tappaas-cicd."; exit 1; }

header "TAPPaaS Immich Verification Tests"
log "Timestamp : $(date)"
log "Target    : tappaas@${TARGET}"
log "Log file  : ${LOG_FILE}"

inf "Checking connectivity to ${TARGET}..."
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi
inf "Connection established."

# ── Test 1: Immich server service ─────────────────────────────────────────────
header "Test 1: Immich Server Service"
IM_STATUS=$(remote "systemctl is-active immich-server 2>/dev/null || echo inactive")
if [[ "${IM_STATUS}" == "active" ]]; then
    pass "immich-server service is active"
else
    fail "immich-server service is ${IM_STATUS}"
fi

# ── Test 2: Machine learning service ──────────────────────────────────────────
header "Test 2: Machine Learning Service"
if [[ "${_ML}" == "true" ]]; then
    ML_STATUS=$(remote "systemctl is-active immich-machine-learning 2>/dev/null || echo inactive")
    if [[ "${ML_STATUS}" == "active" ]]; then
        pass "immich-machine-learning service is active"
    else
        fail "immich-machine-learning service is ${ML_STATUS}"
    fi
else
    skip "machine learning disabled in immich.json (machineLearning=false)"
fi

# ── Test 3: PostgreSQL + vector extensions ────────────────────────────────────
header "Test 3: PostgreSQL Database"
PG_STATUS=$(remote "systemctl is-active postgresql 2>/dev/null || echo inactive")
if [[ "${PG_STATUS}" == "active" ]]; then
    pass "postgresql service is active"
    EXT_COUNT=$(remote "sudo -u postgres psql -d immich -tAc \"SELECT count(*) FROM pg_extension WHERE extname IN ('vchord','vector')\" 2>/dev/null" || echo 0)
    if [[ "${EXT_COUNT}" == "2" ]]; then
        pass "Vector extensions installed (vchord + vector)"
    else
        fail "Expected 2 vector extensions (vchord, vector), found: ${EXT_COUNT}"
    fi
else
    fail "postgresql service is ${PG_STATUS}"
fi

# ── Test 4: Redis ─────────────────────────────────────────────────────────────
header "Test 4: Redis"
REDIS_STATUS=$(remote "systemctl is-active redis-immich 2>/dev/null || echo inactive")
if [[ "${REDIS_STATUS}" == "active" ]]; then
    pass "redis-immich service is active"
else
    fail "redis-immich service is ${REDIS_STATUS}"
fi

# ── Test 5: HTTP API (local + network) ────────────────────────────────────────
header "Test 5: HTTP API"
PING_LOCAL=$(remote "curl -s --max-time 10 http://localhost:2283/api/server/ping 2>/dev/null || echo unreachable")
if [[ "${PING_LOCAL}" == *pong* ]]; then
    pass "Immich API answers on localhost:2283"
else
    fail "Immich API on localhost:2283 returned: ${PING_LOCAL}"
fi
# From cicd via the network — proves host=0.0.0.0 and the firewall port
PING_NET=$(curl -s --max-time 10 "http://${TARGET}:2283/api/server/ping" 2>/dev/null || echo unreachable)
if [[ "${PING_NET}" == *pong* ]]; then
    pass "Immich API reachable over the network (${TARGET}:2283)"
else
    fail "Immich API not reachable from tappaas-cicd (got: ${PING_NET}) — check host=0.0.0.0 and firewall"
fi

# ── Test 6: ML endpoint (localhost only, by design) ───────────────────────────
header "Test 6: ML Endpoint"
if [[ "${_ML}" == "true" ]]; then
    ML_PING=$(remote "curl -s --max-time 10 http://localhost:3003/ping 2>/dev/null || echo unreachable")
    if [[ -n "${ML_PING}" && "${ML_PING}" != "unreachable" ]]; then
        pass "ML service answers on localhost:3003"
    else
        fail "ML service on localhost:3003 not responding"
    fi
else
    skip "machine learning disabled in immich.json (machineLearning=false)"
fi

# ── Test 7: Data disk mount + ownership ───────────────────────────────────────
header "Test 7: Data Disk"
MOUNT_OK=$(remote "mountpoint -q /var/lib/immich && echo yes || echo no")
if [[ "${MOUNT_OK}" == "yes" ]]; then
    pass "/var/lib/immich is mounted"
    DISK_INFO=$(remote "df -h /var/lib/immich | tail -1" || true)
    inf "  ${DISK_INFO}"
else
    fail "/var/lib/immich is not mounted — run services/photostorage/install-service.sh"
fi
OWNER=$(remote "stat -c %U /var/lib/immich 2>/dev/null || echo unknown")
if [[ "${OWNER}" == "immich" ]]; then
    pass "/var/lib/immich is owned by immich"
else
    fail "/var/lib/immich owner is '${OWNER}' (expected immich)"
fi

# ── Test 8: Backup plumbing ───────────────────────────────────────────────────
header "Test 8: Backups"
BACKUP_DIR=$(remote "test -d /var/backup/immich/postgresql && echo yes || echo no")
if [[ "${BACKUP_DIR}" == "yes" ]]; then
    pass "Backup directory /var/backup/immich/postgresql exists"
else
    fail "Backup directory /var/backup/immich/postgresql missing"
fi
TIMER=$(remote "systemctl list-timers --all 2>/dev/null | grep -c postgresqlBackup" || echo 0)
if [[ "${TIMER}" -ge 1 ]]; then
    pass "postgresqlBackup timer is scheduled"
else
    fail "postgresqlBackup timer not found"
fi

# ── Test 9: OIDC/OAuth status (conditional — mirrors nextcloud's Test 11) ────
header "Test 9: OIDC/OAuth Status (identity:identity automation)"
OIDC_SECRET_PRESENT=$(remote "sudo test -f /etc/secrets/immich.env && echo yes || echo no" 2>/dev/null || echo "no")

if [[ "${OIDC_SECRET_PRESENT}" == "no" ]]; then
    skip "OIDC: /etc/secrets/immich.env not present — identity:identity not wired yet, skipping"
else
    API_KEY_PRESENT=$(remote "sudo test -f /etc/secrets/immich-admin-api-key && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "${API_KEY_PRESENT}" == "yes" ]]; then
        pass "Admin API key present at /etc/secrets/immich-admin-api-key"
        inf "Checking oauth.enabled via the authenticated system-config API..."
        # /api/server/config (public/unauthenticated) has no oauth-enabled
        # boolean to check — it only echoes button text. /api/system-config
        # (authenticated) is the same endpoint immich-configure-oidc.service
        # itself writes to, so it's the authoritative source here.
        OAUTH_ENABLED=$(remote 'curl -s --max-time 10 -H "x-api-key: $(sudo cat /etc/secrets/immich-admin-api-key)" http://localhost:2283/api/system-config' \
            | jq -r '.oauth.enabled // empty' 2>/dev/null || echo "")
        if [[ "${OAUTH_ENABLED}" == "true" ]]; then
            pass "Immich reports oauth.enabled=true — OIDC automation applied"
        else
            fail "oauth.enabled is not true (got: '${OAUTH_ENABLED}') — check: ${SSH_CMD} journalctl -u immich-configure-oidc"
        fi
    else
        fail "Admin API key missing — immich-configure-oidc.service cannot apply OAuth settings (see INSTALL.md → Authentik OIDC → manual fallback)"
    fi
fi

# ── Test 10: Resource usage ───────────────────────────────────────────────────
header "Test 10: Resource Usage"
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
