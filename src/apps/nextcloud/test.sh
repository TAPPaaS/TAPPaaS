#!/usr/bin/env bash
# TAPPaaS Nextcloud Verification Test Script
#
# Runs all 10 verification tests for Nextcloud installation.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh
#
# Results are displayed on screen and logged to ~/logs/nextcloud-test-<timestamp>.log

set -euo pipefail

# Configuration — read vmname and zone from the (variant-aware) effective
# config, never hardcode the base name or zone. The module name arrives as $1
# (test-module.sh passes it); fall back to the base module for direct runs.
readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE="${1:-nextcloud}"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
if [[ -f "${MODULE_JSON}" ]]; then
    VMNAME=$(jq -r '.vmname // "nextcloud"' "${MODULE_JSON}")
    ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
else
    VMNAME="${MODULE}"
    ZONE="srv"
fi
TARGET="${VMNAME}.${ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/${MODULE}-test-${TIMESTAMP}.log"

# Color definitions
YW='\033[33m'    # Yellow
RD='\033[01;31m' # Red
GN='\033[32m'    # Green
BL='\033[34m'    # Blue
CL='\033[m'      # Clear
BOLD='\033[1m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Create log directory
mkdir -p "$LOG_DIR"

# Logging function - writes to both screen and log file
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Test result functions
pass() {
    log "${GN}[PASS]${CL} $1"
    ((++PASSED))
}

fail() {
    log "${RD}[FAIL]${CL} $1"
    ((++FAILED))
}

skip() {
    log "${YW}[SKIP]${CL} $1"
    ((++SKIPPED))
}

info() {
    log "${BL}[INFO]${CL} $1"
}

header() {
    log ""
    log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
    log "${BOLD}  $1${CL}"
    log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
}

subheader() {
    log ""
    log "${BOLD}--- $1 ---${CL}"
}

# Remote command helper
remote() {
    $SSH_CMD "$1" 2>/dev/null
}

# Check hostname
if [ "$(hostname)" != "tappaas-cicd" ]; then
    echo -e "${RD}[ERROR]${CL} This script must be run on tappaas-cicd."
    exit 1
fi

# Start tests
header "TAPPaaS Nextcloud Verification Tests"
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

# If not connected, skip all remaining tests
if [ "$CONNECTED" = "false" ]; then
    log ""
    log "${YW}[WARN]${CL} VM unreachable — skipping all remaining tests."
    for i in 2 3 4 5 6 7 8 9 10 11; do
        skip "Test $i skipped (no connectivity)"
    done
    header "Test Summary"
    log ""
    log "Results:"
    log "  ${GN}Passed:${CL}  $PASSED"
    log "  ${RD}Failed:${CL}  $FAILED"
    log "  ${YW}Skipped:${CL} $SKIPPED"
    log ""
    log "Total tests: $((PASSED + FAILED + SKIPPED))"
    log ""
    log "${RD}${BOLD}VM unreachable. No tests could run.${CL}"
    log ""
    log "Full log saved to: ${LOG_FILE}"
    exit 1
fi

info "Connection established."

# ============================================================================
# Test 2: Nextcloud HTTP Response
# ============================================================================
header "Test 2: Nextcloud HTTP Response"
info "Checking HTTP response from http://${TARGET}:80/ ..."

HTTP_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:80/" || echo "000")

if [ "$HTTP_CODE" = "200" ] || [[ "$HTTP_CODE" =~ ^30[0-9]$ ]]; then
    pass "HTTP response code $HTTP_CODE (OK or redirect)"
else
    fail "Unexpected HTTP response code: $HTTP_CODE (expected 200 or 3xx)"
fi

# ============================================================================
# Test 3: Nextcloud Application Status (config.php)
# ============================================================================
# nextcloud-occ uses systemd-run --pty internally which does not relay output
# over SSH in batch/non-TTY sessions. We read config.php directly instead.
header "Test 3: Nextcloud Application Status (config.php)"
info "Checking 'installed' flag in /var/lib/nextcloud/config/config.php..."

INSTALLED_LINE=$(remote "sudo -u nextcloud grep \"'installed'\" /var/lib/nextcloud/config/config.php 2>/dev/null" || echo "")

if echo "$INSTALLED_LINE" | grep -q "true"; then
    pass "Nextcloud reports installed: true"
elif [ -n "$INSTALLED_LINE" ]; then
    fail "Nextcloud config.php shows installed: false or unknown"
    log "  config line: $INSTALLED_LINE"
else
    fail "Could not read Nextcloud config.php (installed flag missing)"
fi

# Maintenance mode — only present in config.php when enabled
MAINT_LINE=$(remote "sudo -u nextcloud grep \"'maintenance'\" /var/lib/nextcloud/config/config.php 2>/dev/null" || echo "")
if echo "$MAINT_LINE" | grep -q "true"; then
    log "${YW}[WARN]${CL} Nextcloud is in maintenance mode"
else
    info "Maintenance mode: off"
fi

# ============================================================================
# Test 4: PostgreSQL Service + Nextcloud Database
# ============================================================================
header "Test 4: PostgreSQL Service and Nextcloud Database"

subheader "Service: postgresql"
PG_STATUS=$(remote "systemctl is-active postgresql 2>/dev/null" || echo "unknown")
if [ "$PG_STATUS" = "active" ]; then
    pass "postgresql service is active"
else
    fail "postgresql service is ${PG_STATUS}"
fi

subheader "Nextcloud database accessibility"
NC_DB_CHECK=$(remote "sudo -u postgres psql -t -c \"SELECT 1 FROM pg_database WHERE datname='nextcloud';\" 2>/dev/null" || echo "")
NC_DB_CHECK=$(echo "$NC_DB_CHECK" | tr -d '[:space:]')

if [ "$NC_DB_CHECK" = "1" ]; then
    pass "nextcloud database exists and is accessible"
else
    fail "nextcloud database not found or not accessible"
fi

# ============================================================================
# Test 5: Redis Service (Unix Socket)
# ============================================================================
header "Test 5: Redis Service"

subheader "Service: redis-nextcloud"
REDIS_STATUS=$(remote "systemctl is-active redis-nextcloud 2>/dev/null" || echo "unknown")
if [ "$REDIS_STATUS" = "active" ]; then
    pass "redis-nextcloud service is active"
else
    fail "redis-nextcloud service is ${REDIS_STATUS}"
fi

subheader "Redis unix socket: /run/redis-nextcloud/redis.sock"
SOCK_CHECK=$(remote "sudo test -S /run/redis-nextcloud/redis.sock && echo exists || echo missing" 2>/dev/null || echo "missing")
if [ "$SOCK_CHECK" = "exists" ]; then
    pass "Redis unix socket /run/redis-nextcloud/redis.sock exists"
else
    fail "Redis unix socket /run/redis-nextcloud/redis.sock not found"
fi

# ============================================================================
# Test 6: Backup Directories
# ============================================================================
header "Test 6: Backup Directories"
info "Checking backup directory structure..."

subheader "/var/backup/nextcloud/postgresql"
PG_BACKUP=$(remote "test -d /var/backup/nextcloud/postgresql && echo exists || echo missing" 2>/dev/null || echo "missing")
if [ "$PG_BACKUP" = "exists" ]; then
    pass "/var/backup/nextcloud/postgresql exists"
else
    skip "/var/backup/nextcloud/postgresql not found — created on first backup timer run"
fi

subheader "/var/backup/nextcloud/data"
DATA_BACKUP=$(remote "test -d /var/backup/nextcloud/data && echo exists || echo missing" 2>/dev/null || echo "missing")
if [ "$DATA_BACKUP" = "exists" ]; then
    pass "/var/backup/nextcloud/data exists"
else
    skip "/var/backup/nextcloud/data not found — created on first backup timer run"
fi

# ============================================================================
# Test 7: Backup Timers Active
# ============================================================================
header "Test 7: Backup Timers"
info "Checking systemd backup timers..."

subheader "Timer: nextcloud-data-backup.timer"
DATA_TIMER=$(remote "systemctl is-active nextcloud-data-backup.timer 2>/dev/null" || echo "unknown")
if [ "$DATA_TIMER" = "active" ]; then
    pass "nextcloud-data-backup.timer is active"
else
    fail "nextcloud-data-backup.timer is ${DATA_TIMER}"
fi

subheader "Timer: postgresqlBackup-nextcloud.timer"
PG_TIMER=$(remote "systemctl is-active postgresqlBackup-nextcloud.timer 2>/dev/null" || echo "unknown")
if [ "$PG_TIMER" = "active" ]; then
    pass "postgresqlBackup-nextcloud.timer is active"
else
    fail "postgresqlBackup-nextcloud.timer is ${PG_TIMER}"
fi

# ============================================================================
# Test 8: Secret Files Exist with Correct Permissions
# ============================================================================
header "Test 8: Secret File Permissions"
info "Checking secret files exist and have mode 0600..."

subheader "/var/lib/nextcloud/admin-pass"
ADMIN_PASS_CHECK=$(remote "sudo stat -c '%a %F' /var/lib/nextcloud/admin-pass 2>/dev/null" || echo "")
ADMIN_PASS_MODE=$(echo "$ADMIN_PASS_CHECK" | awk '{print $1}')
ADMIN_PASS_TYPE=$(echo "$ADMIN_PASS_CHECK" | awk '{print $2}')

if [ "$ADMIN_PASS_TYPE" = "regular" ] && [ "$ADMIN_PASS_MODE" = "600" ]; then
    pass "/var/lib/nextcloud/admin-pass exists with mode 0600"
elif [ -n "$ADMIN_PASS_CHECK" ]; then
    fail "/var/lib/nextcloud/admin-pass exists but mode is ${ADMIN_PASS_MODE} (expected 600)"
else
    fail "/var/lib/nextcloud/admin-pass not found"
fi

subheader "/var/lib/nextcloud/db-pass"
DB_PASS_CHECK=$(remote "sudo stat -c '%a %F' /var/lib/nextcloud/db-pass 2>/dev/null" || echo "")
DB_PASS_MODE=$(echo "$DB_PASS_CHECK" | awk '{print $1}')
DB_PASS_TYPE=$(echo "$DB_PASS_CHECK" | awk '{print $2}')

if [ "$DB_PASS_TYPE" = "regular" ] && [ "$DB_PASS_MODE" = "600" ]; then
    pass "/var/lib/nextcloud/db-pass exists with mode 0600"
elif [ -n "$DB_PASS_CHECK" ]; then
    fail "/var/lib/nextcloud/db-pass exists but mode is ${DB_PASS_MODE} (expected 600)"
else
    fail "/var/lib/nextcloud/db-pass not found"
fi

# ============================================================================
# Test 9: Firewall — Ports 22 and 80 Open, Port 9980 Closed
# ============================================================================
header "Test 9: Firewall Port Checks"
info "Checking open/closed ports from tappaas-cicd..."

subheader "Port 22 (SSH) — should be open"
if nc -z -w5 "${TARGET}" 22 2>/dev/null; then
    pass "Port 22 is open on ${TARGET}"
else
    fail "Port 22 is not reachable on ${TARGET}"
fi

subheader "Port 80 (HTTP) — should be open"
if nc -z -w5 "${TARGET}" 80 2>/dev/null; then
    pass "Port 80 is open on ${TARGET}"
else
    fail "Port 80 is not reachable on ${TARGET}"
fi

subheader "Port 9980 (Collabora) — should be CLOSED (no Collabora)"
if nc -z -w5 "${TARGET}" 9980 2>/dev/null; then
    fail "Port 9980 is open on ${TARGET} — Collabora should NOT be running here"
else
    pass "Port 9980 is closed on ${TARGET} (correct — office handled by euro-office module)"
fi

# ============================================================================
# Test 10: Data Backup Service (smoke test)
# ============================================================================
header "Test 10: Data Backup Service"
info "Triggering nextcloud-data-backup.service (oneshot) — this may take a moment..."

# Robust against clock skew / future-dated files: compare the full SET of backup
# files before/after by filename, not the newest-by-mtime (a single file with a
# future mtime — e.g. from a fresh VM before NTP sync — would otherwise shadow
# every new backup under `ls -t` and cause a false negative).
BACKUP_BEFORE=$(remote "sudo bash -c 'ls /var/backup/nextcloud/data/*.tar.gz 2>/dev/null | sort'" || echo "")

if remote "sudo systemctl start nextcloud-data-backup.service" 2>/dev/null; then
    BACKUP_AFTER=$(remote "sudo bash -c 'ls /var/backup/nextcloud/data/*.tar.gz 2>/dev/null | sort'" || echo "")
    NEW_BACKUP=$(comm -13 <(printf '%s\n' "$BACKUP_BEFORE") <(printf '%s\n' "$BACKUP_AFTER") | grep -v '^$' | tail -1)
    if [ -n "$NEW_BACKUP" ]; then
        BACKUP_SIZE=$(remote "sudo du -sh '$NEW_BACKUP' 2>/dev/null | cut -f1" || echo "?")
        pass "Data backup succeeded — ${NEW_BACKUP##*/} (${BACKUP_SIZE})"
    elif [ -n "$BACKUP_AFTER" ]; then
        fail "Backup service exited 0 but no new .tar.gz appeared in /var/backup/nextcloud/data/"
    else
        fail "Backup service exited 0 but /var/backup/nextcloud/data/ is empty"
    fi
else
    JOURNAL=$(remote "sudo journalctl -u nextcloud-data-backup.service -n 5 --no-pager 2>/dev/null" || echo "(no journal)")
    fail "nextcloud-data-backup.service failed"
    log "  Last journal lines:"
    while IFS= read -r line; do log "    $line"; done <<< "$JOURNAL"
fi

# ============================================================================
# Test 11: OIDC App Status (conditional)
# ============================================================================
header "Test 11: OIDC App Status (user_oidc)"

OIDC_SECRET_PRESENT=$(remote "sudo test -f /etc/secrets/nextcloud.env && echo yes || echo no" 2>/dev/null || echo "no")

if [ "$OIDC_SECRET_PRESENT" = "no" ]; then
    skip "OIDC: /etc/secrets/nextcloud.env not present — OIDC not configured, skipping"
else
    info "/etc/secrets/nextcloud.env found — checking user_oidc app status (via PostgreSQL)..."
    OIDC_DB_STATUS=$(remote "sudo -u postgres psql -d nextcloud -tAc \"SELECT configvalue FROM oc_appconfig WHERE appid='user_oidc' AND configkey='enabled'\" 2>/dev/null" || echo "")
    OIDC_DB_STATUS="${OIDC_DB_STATUS// /}"  # trim whitespace

    if [ "$OIDC_DB_STATUS" = "yes" ]; then
        pass "user_oidc app is installed and enabled"
    elif [ "$OIDC_DB_STATUS" = "no" ]; then
        fail "user_oidc app is installed but DISABLED in database"
    else
        fail "user_oidc app not found in database (got: '$OIDC_DB_STATUS')"
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
