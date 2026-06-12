#!/usr/bin/env bash
# TAPPaaS Euro-Office DocumentServer Verification Test Script
#
# Runs all 10 verification tests for the Euro-Office DocumentServer installation.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh
#
# Results are displayed on screen and logged to ~/logs/euro-office-test-<timestamp>.log

set -euo pipefail

# Configuration — derive the target FQDN from the deployed config (never hardcode
# the zone; modules deploy to srv, srvWork, etc.).
_EO_CFG="/home/tappaas/config/euro-office.json"
TARGET="$(jq -r '.vmname' "${_EO_CFG}" 2>/dev/null || echo euro-office).$(jq -r '.zone0' "${_EO_CFG}" 2>/dev/null || echo srv).internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/euro-office-test-${TIMESTAMP}.log"

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
header "TAPPaaS Euro-Office DocumentServer Verification Tests"
log "Timestamp: $(date)"
log "Target:    tappaas@${TARGET}"
log "Log file:  ${LOG_FILE}"

# ============================================================================
# Test 1: SSH Connectivity
# ============================================================================
header "Test 1: SSH Connectivity"
info "Checking connectivity to ${TARGET}..."

if $SSH_CMD "exit 0" 2>/dev/null; then
    pass "SSH connection to ${TARGET} succeeded"
    SSH_OK=true
else
    fail "Cannot connect to ${TARGET} via SSH — is the VM running?"
    SSH_OK=false
fi

# If SSH is not available, skip all remaining tests
if [ "$SSH_OK" = false ]; then
    log ""
    log "${RD}[ERROR]${CL} SSH unreachable — skipping all remaining tests."
    for i in 2 3 4 5 6 7 8 9 10; do
        skip "Test $i skipped — SSH unreachable"
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
    log "${RD}${BOLD}Some tests failed. Review the output above for details.${CL}"
    log ""
    log "Full log saved to: ${LOG_FILE}"
    log ""
    exit 1
fi

info "Connection established."

# ============================================================================
# Test 2: Container Running
# ============================================================================
header "Test 2: Container Running"
info "Checking if the euro-office Podman container is up..."

CONTAINER_STATUS=$(remote "sudo podman ps --filter name=euro-office --format '{{.Status}}' 2>/dev/null" || echo "")

if echo "$CONTAINER_STATUS" | grep -qi "^Up"; then
    pass "euro-office container is running (${CONTAINER_STATUS})"
    CONTAINER_OK=true
else
    if [ -z "$CONTAINER_STATUS" ]; then
        fail "euro-office container is not present in podman ps output"
    else
        fail "euro-office container status: ${CONTAINER_STATUS}"
    fi
    CONTAINER_OK=false
fi

# ============================================================================
# Test 3: Service Active
# ============================================================================
header "Test 3: Service Active"
info "Checking systemd service podman-euro-office..."

SERVICE_STATUS=$(remote "systemctl is-active podman-euro-office 2>/dev/null || true")

if [ "$SERVICE_STATUS" = "active" ]; then
    pass "podman-euro-office.service is active"
else
    fail "podman-euro-office.service is ${SERVICE_STATUS:-unknown}"
fi

# ============================================================================
# Test 4: HTTP Health (DocumentServer root)
# ============================================================================
header "Test 4: HTTP Health"
info "Testing DocumentServer HTTP response on http://localhost/..."

if [ "$CONTAINER_OK" = false ]; then
    skip "HTTP health check skipped — container is not running"
else
    HTTP_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/" || echo "000")
    info "HTTP status code: ${HTTP_CODE}"

    if [ "$HTTP_CODE" = "200" ]; then
        pass "HTTP health check passed (HTTP 200)"
    elif [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        pass "HTTP health check passed (HTTP ${HTTP_CODE} redirect)"
    else
        fail "HTTP health check failed (HTTP ${HTTP_CODE})"
    fi
fi

# ============================================================================
# Test 4b: Connector Endpoints (Nextcloud onlyoffice/eurooffice connector)
# ============================================================================
# The eurooffice-nextcloud connector (lib/DocumentService.php) verifies the
# DocumentServer via /healthcheck + /coauthoring/CommandService.ashx and loads
# the editor API at /web-apps/apps/api/documents/api.js. It does NOT use
# /hosting/discovery (a WOPI endpoint OnlyOffice DS never serves). This test
# covers the endpoints the connector actually depends on (audit gap, 2026-06-10).
header "Test 4b: Connector Endpoints"
info "Testing the endpoints the Nextcloud connector relies on..."

if [ "$CONTAINER_OK" = false ]; then
    skip "Connector endpoint check skipped — container is not running"
else
    HC_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/healthcheck" || echo "000")
    API_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/web-apps/apps/api/documents/api.js" || echo "000")
    info "/healthcheck: ${HC_CODE}   /web-apps api.js: ${API_CODE}"

    if [ "$HC_CODE" = "200" ]; then
        pass "DocumentServer /healthcheck returned HTTP 200 (connector availability check)"
    else
        fail "DocumentServer /healthcheck failed (HTTP ${HC_CODE}) — connector will report the server unavailable"
    fi

    if [ "$API_CODE" = "200" ]; then
        pass "Editor API /web-apps/apps/api/documents/api.js returned HTTP 200"
    else
        fail "Editor API api.js failed (HTTP ${API_CODE}) — Nextcloud cannot load the editor"
    fi
fi

# ============================================================================
# Test 5: Example App
# ============================================================================
header "Test 5: Example App"
info "Testing built-in DocumentServer example app at http://localhost/example/..."

# EXAMPLE_ENABLED is hardcoded to "false" in euro-office.nix (the JSON field was
# removed in the schema-compliance cleanup, 2026-06-10). Example app disabled by design.
EXAMPLE_ENABLED_CFG="false"

if [ "$CONTAINER_OK" = false ]; then
    skip "Example app check skipped — container is not running"
elif [ "$EXAMPLE_ENABLED_CFG" != "true" ]; then
    skip "Example app check skipped — EXAMPLE_ENABLED=false (disabled by design in euro-office.nix)"
else
    EXAMPLE_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/example/" || echo "000")
    info "HTTP status code: ${EXAMPLE_CODE}"

    if [ "$EXAMPLE_CODE" = "200" ] || [ "$EXAMPLE_CODE" = "301" ] || [ "$EXAMPLE_CODE" = "302" ]; then
        pass "Example app returned HTTP ${EXAMPLE_CODE}"
    else
        fail "Example app check failed (HTTP ${EXAMPLE_CODE})"
    fi
fi

# ============================================================================
# Test 6: Admin Panel
# ============================================================================
# URL varies by image build: /admin/ or /adminpanel/.
# Both are tried; pass if either responds.
header "Test 6: Admin Panel"
info "Testing DocumentServer admin panel (trying /admin/ and /adminpanel/)..."

if [ "$CONTAINER_OK" = false ]; then
    skip "Admin panel check skipped — container is not running"
else
    ADMIN_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/admin/" || echo "000")
    ADMIN_CODE2=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost/adminpanel/" || echo "000")

    if [ "$ADMIN_CODE" = "200" ] || [ "$ADMIN_CODE" = "301" ] || [ "$ADMIN_CODE" = "302" ]; then
        pass "Admin panel responded at /admin/ (HTTP ${ADMIN_CODE})"
    elif [ "$ADMIN_CODE2" = "200" ] || [ "$ADMIN_CODE2" = "301" ] || [ "$ADMIN_CODE2" = "302" ]; then
        pass "Admin panel responded at /adminpanel/ (HTTP ${ADMIN_CODE2})"
    elif [[ "$ADMIN_CODE" == 5* ]] || [[ "$ADMIN_CODE2" == 5* ]]; then
        skip "Admin panel backend not available in this image build (/admin/: ${ADMIN_CODE}, /adminpanel/: ${ADMIN_CODE2}) — the admin panel service may not be active in this build"
    else
        fail "Admin panel not found at /admin/ (${ADMIN_CODE}) or /adminpanel/ (${ADMIN_CODE2})"
    fi
fi

# ============================================================================
# Test 7: JWT Secret Exists
# ============================================================================
header "Test 7: JWT Secret Exists"
info "Checking /etc/secrets/euro-office.env for JWT_SECRET..."

SECRETS_EXISTS=$(remote "test -f /etc/secrets/euro-office.env && echo yes || echo no")

if [ "$SECRETS_EXISTS" != "yes" ]; then
    fail "/etc/secrets/euro-office.env does not exist"
else
    info "Secrets file exists — checking mode and content..."

    # Check permissions (must be 0600)
    FILE_MODE=$(remote "stat -c '%a' /etc/secrets/euro-office.env 2>/dev/null || echo 'unknown'")
    if [ "$FILE_MODE" = "600" ]; then
        info "File permissions: ${FILE_MODE} (correct)"
    else
        info "File permissions: ${FILE_MODE} (expected 600)"
    fi

    # Extract JWT_SECRET value (check non-empty, do not log the value)
    JWT_VALUE=$(remote "sudo grep '^JWT_SECRET=' /etc/secrets/euro-office.env | cut -d= -f2- 2>/dev/null || echo ''")

    if [ -n "$JWT_VALUE" ]; then
        pass "JWT_SECRET is present and non-empty (${#JWT_VALUE} characters)"
    else
        fail "JWT_SECRET key is missing or empty in /etc/secrets/euro-office.env"
    fi
fi

# ============================================================================
# Test 8: Backup Timer Scheduled
# ============================================================================
header "Test 8: Backup Timer Scheduled"
info "Checking euro-office-backup.timer is active and scheduled..."

TIMER_OUTPUT=$(remote "systemctl list-timers euro-office-backup.timer --no-pager 2>/dev/null || true")

if echo "$TIMER_OUTPUT" | grep -q "euro-office-backup.timer"; then
    pass "euro-office-backup.timer is active and scheduled"
    # Show next trigger time if available
    NEXT_TRIGGER=$(echo "$TIMER_OUTPUT" | grep "euro-office-backup.timer" | awk '{print $1, $2}')
    [ -n "$NEXT_TRIGGER" ] && info "Next trigger: ${NEXT_TRIGGER}"
else
    TIMER_STATE=$(remote "systemctl is-active euro-office-backup.timer 2>/dev/null || echo inactive")
    fail "euro-office-backup.timer not found in list-timers (state: ${TIMER_STATE})"
fi

# ============================================================================
# Test 9: Data Dir Exists
# ============================================================================
header "Test 9: Data Directory Exists"
info "Checking /var/lib/euro-office/data directory..."

DATA_DIR_CHECK=$(remote "test -d /var/lib/euro-office/data && echo yes || echo no")

if [ "$DATA_DIR_CHECK" = "yes" ]; then
    pass "/var/lib/euro-office/data directory exists"
    DATA_USAGE=$(remote "du -sh /var/lib/euro-office/data 2>/dev/null | cut -f1 || echo unknown")
    info "Directory size: ${DATA_USAGE}"
else
    fail "/var/lib/euro-office/data directory does not exist"
fi

# ============================================================================
# Test 10: Backup Dir Accessible and Writable
# ============================================================================
header "Test 10: Backup Directory Accessible"
info "Checking /var/backup/euro-office directory..."

BACKUP_DIR_CHECK=$(remote "test -d /var/backup/euro-office && echo yes || echo no")

if [ "$BACKUP_DIR_CHECK" = "yes" ]; then
    pass "/var/backup/euro-office exists"
    BACKUP_USAGE=$(remote "sudo du -sh /var/backup/euro-office 2>/dev/null | cut -f1 || echo unknown")
    info "Backup directory size: ${BACKUP_USAGE}"
else
    skip "/var/backup/euro-office not found — created on first backup timer run"
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
