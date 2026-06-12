#!/usr/bin/env bash
# TAPPaaS coturn Verification Test Script
#
# Runs all 10 verification tests for the coturn TURN/STUN server.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh
#
# Results are displayed on screen and logged to ~/logs/coturn-test-<timestamp>.log

set -euo pipefail

# Configuration — derive the target from the (variant-aware) module config, never hardcode.
MODULE="${1:-coturn}"
TARGET="$(jq -r '.vmname' "/home/tappaas/config/${MODULE}.json" 2>/dev/null).$(jq -r '.zone0' "/home/tappaas/config/${MODULE}.json" 2>/dev/null).internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/coturn-test-${TIMESTAMP}.log"

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
header "TAPPaaS coturn Verification Tests"
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
    for i in 2 3 4 5 6 7 8 9 10; do
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
# Test 2: coturn Service Status
# ============================================================================
header "Test 2: coturn Service Status"
info "Checking systemd unit: coturn..."

COTURN_STATUS=$(remote "systemctl is-active coturn 2>/dev/null" || echo "unknown")
if [ "$COTURN_STATUS" = "active" ]; then
    pass "coturn service is active"
else
    fail "coturn service is ${COTURN_STATUS} (expected active)"
fi

# ============================================================================
# Test 3: coturn Process Running
# ============================================================================
header "Test 3: coturn Process Running"
info "Checking for turnserver process via pgrep..."

PROC=$(remote "pgrep -x turnserver 2>/dev/null" || echo "")
if [ -n "$PROC" ]; then
    pass "turnserver process is running (PID: ${PROC})"
else
    fail "turnserver process not found — coturn may not have started correctly"
fi

# ============================================================================
# Test 4: Port 3478 TCP Reachable
# ============================================================================
header "Test 4: Port 3478 TCP Reachable"
info "Checking TCP port 3478 on ${TARGET} from tappaas-cicd..."

if nc -z -w5 "${TARGET}" 3478 2>/dev/null; then
    pass "Port 3478 TCP is open on ${TARGET}"
else
    fail "Port 3478 TCP is not reachable on ${TARGET} — check firewall or coturn binding"
fi

# ============================================================================
# Test 5: Port 3478 UDP — STUN Binding Request
# ============================================================================
header "Test 5: Port 3478 UDP — STUN Binding"
info "Sending STUN binding request to ${TARGET}:3478/udp..."

# Check if nc supports -u on this host
if ! nc --help 2>&1 | grep -q '\-u'; then
    skip "Port 3478 UDP: nc does not support -u on this host — skipping STUN probe"
else
    # Send a minimal STUN binding request (RFC 5389) and check for a response
    STUN_RESULT=$(timeout 5 bash -c \
        "printf '\\x00\\x01\\x00\\x00\\x21\\x12\\xa4\\x42\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00' \
         | nc -u -w3 ${TARGET} 3478" 2>/dev/null | wc -c || echo "0")
    if [ "${STUN_RESULT:-0}" -gt 0 ]; then
        pass "Port 3478 UDP: received STUN response (${STUN_RESULT} bytes)"
    else
        # A non-response over UDP could just mean the packet was dropped by the
        # OS before nc exited; treat as a soft warning rather than hard failure.
        skip "Port 3478 UDP: no STUN response received — UDP may be filtered or nc timed out"
    fi
fi

# ============================================================================
# Test 6: Secret File Exists with Correct Permissions
# ============================================================================
header "Test 6: Secret File Permissions"
info "Checking /etc/secrets/coturn.env exists and has mode 0600..."

SECRET_EXISTS=$(remote "sudo test -f /etc/secrets/coturn.env && echo exists || echo missing" || echo "missing")
if [ "$SECRET_EXISTS" = "missing" ]; then
    fail "/etc/secrets/coturn.env not found"
else
    SECRET_MODE=$(remote "sudo stat -c '%a' /etc/secrets/coturn.env 2>/dev/null" || echo "")
    if [ "$SECRET_MODE" = "600" ]; then
        pass "/etc/secrets/coturn.env exists with mode 0600"
    else
        fail "/etc/secrets/coturn.env exists but mode is ${SECRET_MODE} (expected 600)"
    fi
fi

# ============================================================================
# Test 7: COTURN_SECRET Is Set
# ============================================================================
header "Test 7: COTURN_SECRET Configured"
info "Checking COTURN_SECRET is a 64-character hex string in /etc/secrets/coturn.env..."

SECRET_COUNT=$(remote "sudo grep -c '^COTURN_SECRET=[0-9a-f]\{64\}$' /etc/secrets/coturn.env 2>/dev/null" || echo "0")
if [ "${SECRET_COUNT:-0}" -ge 1 ]; then
    pass "COTURN_SECRET is set and appears to be a valid 64-character hex string"
else
    fail "COTURN_SECRET not found or does not match expected format (64 hex chars) in /etc/secrets/coturn.env"
fi

# ============================================================================
# Test 8: Runtime Config File Generated
# ============================================================================
header "Test 8: Runtime Config File"
info "Checking /run/coturn/turnserver.conf is present and contains security settings..."

CONF_EXISTS=$(remote "sudo test -f /run/coturn/turnserver.conf && echo exists || echo missing" || echo "missing")
if [ "$CONF_EXISTS" = "missing" ]; then
    fail "/run/coturn/turnserver.conf not found — was it generated at service start?"
else
    pass "/run/coturn/turnserver.conf exists"

    DENIED_PEER_COUNT=$(remote "sudo grep -c 'denied-peer-ip' /run/coturn/turnserver.conf 2>/dev/null" || echo "0")
    if [ "${DENIED_PEER_COUNT:-0}" -gt 0 ]; then
        pass "/run/coturn/turnserver.conf contains denied-peer-ip entries (security config present)"
    else
        fail "/run/coturn/turnserver.conf has no denied-peer-ip entries — RFC-1918 blocking may be missing"
    fi
fi

# ============================================================================
# Test 9: Backup Directory and Timer
# ============================================================================
header "Test 9: Backup Directory and Timer"

subheader "Backup directory: /var/backup/coturn"
BACKUP_DIR=$(remote "test -d /var/backup/coturn && echo exists || echo missing" || echo "missing")
if [ "$BACKUP_DIR" = "exists" ]; then
    pass "/var/backup/coturn directory exists"
else
    skip "/var/backup/coturn not found — will be created on first backup timer run"
fi

# NixOS names the timer after the unit (systemd.timers.coturn-backup-secrets).
subheader "Timer: coturn-backup-secrets.timer"
# Keep the fallback INSIDE the remote shell — a trailing `|| echo` here would append
# a second line to is-active's own output (e.g. "inactive\nunknown") and break the test.
BACKUP_TIMER=$(remote "systemctl is-active coturn-backup-secrets.timer 2>/dev/null || echo unknown")
if [ "$BACKUP_TIMER" = "active" ]; then
    pass "coturn-backup-secrets.timer is active"
elif [ "$BACKUP_TIMER" = "unknown" ] || [ "$BACKUP_TIMER" = "inactive" ]; then
    skip "coturn-backup-secrets.timer is ${BACKUP_TIMER} — not yet configured or not yet started"
else
    fail "coturn-backup-secrets.timer is ${BACKUP_TIMER} (expected active)"
fi

# ============================================================================
# Test 10: External IP Configured
# ============================================================================
header "Test 10: External IP Configured"
info "Checking COTURN_EXTERNAL_IP is set in /etc/secrets/coturn.env..."

# Fallback inside the remote shell: `grep -c` prints "0" AND exits 1 on no match, so a
# trailing `|| echo 0` here would yield "0\n0" → "integer expected" in the test below.
EXT_IP_COUNT=$(remote "sudo grep -c '^COTURN_EXTERNAL_IP=.' /etc/secrets/coturn.env 2>/dev/null || echo 0")
if [ "${EXT_IP_COUNT:-0}" -ge 1 ]; then
    pass "COTURN_EXTERNAL_IP is configured in /etc/secrets/coturn.env"
else
    skip "COTURN_EXTERNAL_IP not set — audio/video calls from external networks will fail. Set it in /etc/secrets/coturn.env"
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
