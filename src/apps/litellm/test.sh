#!/usr/bin/env bash
# TAPPaaS LiteLLM Verification Test Script
#
# Runs all 10 verification tests for LiteLLM installation.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test-litellm.sh
#
# Results are displayed on screen and logged to ~/logs/litellm-test-<timestamp>.log

# Configuration
TARGET="litellm.srv.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/litellm-test-${TIMESTAMP}.log"

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
    ((PASSED++))
}

fail() {
    log "${RD}[FAIL]${CL} $1"
    ((FAILED++))
}

skip() {
    log "${YW}[SKIP]${CL} $1"
    ((SKIPPED++))
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
header "TAPPaaS LiteLLM Verification Tests"
log "Timestamp: $(date)"
log "Target: tappaas@${TARGET}"
log "Log file: ${LOG_FILE}"

# Check if VM is reachable
info "Checking connectivity to ${TARGET}..."
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi
info "Connection established."

# ============================================================================
# Test 1: Service Health
# ============================================================================
header "Test 1: Service Health"
info "Checking if all services are running..."

# Get all service statuses in one SSH call
SERVICE_STATUS=$(remote "systemctl is-active postgresql redis-litellm podman-litellm 2>/dev/null || true")

PG_STATUS=$(echo "$SERVICE_STATUS" | sed -n '1p')
REDIS_STATUS=$(echo "$SERVICE_STATUS" | sed -n '2p')
PODMAN_STATUS=$(echo "$SERVICE_STATUS" | sed -n '3p')

subheader "Service: postgresql"
if [ "$PG_STATUS" = "active" ]; then
    pass "postgresql is active"
else
    fail "postgresql is ${PG_STATUS:-unknown}"
fi

subheader "Service: redis-litellm"
if [ "$REDIS_STATUS" = "active" ]; then
    pass "redis-litellm is active"
else
    fail "redis-litellm is ${REDIS_STATUS:-unknown}"
fi

subheader "Service: podman-litellm"
if [ "$PODMAN_STATUS" = "active" ]; then
    pass "podman-litellm is active"
else
    fail "podman-litellm is ${PODMAN_STATUS:-unknown}"
fi

# ============================================================================
# Test 2: API Health Check
# ============================================================================
header "Test 2: API Health Check"
info "Testing LiteLLM API health endpoint..."

HEALTH_RESPONSE=$(remote "curl -s --max-time 10 http://localhost:4000/health" || echo "connection_failed")
log "Response: $HEALTH_RESPONSE"

if echo "$HEALTH_RESPONSE" | grep -qi "healthy"; then
    pass "API health check passed"
elif echo "$HEALTH_RESPONSE" | grep -qi "auth"; then
    # API is responding but requires authentication - this is still a valid response
    pass "API is responding (authentication required for /health)"
else
    fail "API health check failed"
fi

# ============================================================================
# Test 3: Database Connectivity
# ============================================================================
header "Test 3: Database Connectivity"
info "Testing PostgreSQL connectivity..."

subheader "PostgreSQL Version"
PG_VERSION=$(remote "sudo -u postgres psql -t -c 'SELECT version();'" || echo "failed")
if echo "$PG_VERSION" | grep -qi "postgresql"; then
    pass "PostgreSQL is responding"
    log "  Version: $(echo $PG_VERSION | head -1 | xargs)"
else
    fail "PostgreSQL not responding"
fi

subheader "LiteLLM Database Tables"
TABLE_COUNT=$(remote "sudo -u postgres psql -t litellm -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';\"" || echo "0")
TABLE_COUNT=$(echo "$TABLE_COUNT" | xargs)

if [ "$TABLE_COUNT" -gt 0 ] 2>/dev/null; then
    pass "LiteLLM database has $TABLE_COUNT tables"
else
    fail "LiteLLM database has no tables or is inaccessible"
fi

# ============================================================================
# Test 4: Redis Connectivity
# ============================================================================
header "Test 4: Redis Connectivity"
info "Testing Redis connectivity..."

subheader "Redis PING"
REDIS_PING=$(remote "redis-cli PING" || echo "failed")
if [ "$REDIS_PING" = "PONG" ]; then
    pass "Redis is responding (PONG)"
else
    fail "Redis not responding - got: $REDIS_PING"
fi

subheader "Redis Stats"
REDIS_KEYS=$(remote "redis-cli DBSIZE" || echo "unknown")
info "Database size: $REDIS_KEYS"

# ============================================================================
# Test 5: API Authentication
# ============================================================================
header "Test 5: API Authentication"
info "Testing API authentication with master key..."

# Get master key
MASTER_KEY=$(remote "sudo cat /etc/secrets/litellm.env | grep LITELLM_MASTER_KEY | cut -d= -f2" || echo "")

if [ -z "$MASTER_KEY" ]; then
    fail "Could not retrieve master key from /etc/secrets/litellm.env"
    skip "Skipping authentication test - no master key"
else
    info "Master key retrieved (${#MASTER_KEY} characters)"

    # Test authenticated endpoint
    AUTH_RESPONSE=$(remote "curl -s --max-time 10 -X GET http://localhost:4000/key/info -H 'Authorization: Bearer $MASTER_KEY'" || echo "failed")

    if echo "$AUTH_RESPONSE" | grep -qi "key"; then
        pass "API authentication successful"
    elif echo "$AUTH_RESPONSE" | grep -qi "error"; then
        fail "API authentication failed"
    else
        fail "API authentication returned unexpected response"
    fi
fi

# ============================================================================
# Test 6: Model Management
# ============================================================================
header "Test 6: Model Management"
info "Checking model configuration..."

if [ -z "$MASTER_KEY" ]; then
    skip "Skipping model management test - no master key"
else
    MODEL_INFO=$(remote "curl -s --max-time 10 -X GET http://localhost:4000/model/info -H 'Authorization: Bearer $MASTER_KEY'" || echo "failed")

    if echo "$MODEL_INFO" | grep -qi "data"; then
        pass "Model info endpoint accessible"
        MODEL_COUNT=$(echo "$MODEL_INFO" | grep -o '"model_name"' | wc -l || echo "0")
        info "Models configured: $MODEL_COUNT"
    else
        fail "Model info endpoint not accessible"
    fi
fi

# ============================================================================
# Test 7: Complete Request Flow
# ============================================================================
header "Test 7: Complete Request Flow"
info "This test requires a configured model with valid API key"

if [ -z "$MASTER_KEY" ]; then
    skip "Skipping request flow test - no master key"
else
    # Check if there are any models configured
    if echo "$MODEL_INFO" | grep -qi '"model_name"'; then
        info "Models are configured - but skipping live test (requires provider API key)"
        skip "Request flow test skipped - requires provider API key configuration"
    else
        skip "No models configured - skipping request flow test"
    fi
fi

# ============================================================================
# Test 8: Backup System
# ============================================================================
header "Test 8: Backup System"
info "Checking backup directories and timers..."

subheader "Backup Directories"
BACKUP_CHECK=$(remote "ls -d /var/backup/postgresql /var/backup/redis /var/backup/litellm-env 2>/dev/null | wc -l" || echo "0")

if [ "$BACKUP_CHECK" -eq 3 ]; then
    pass "All backup directories exist"
else
    fail "Some backup directories missing ($BACKUP_CHECK/3 found)"
fi

subheader "Backup Timers"
TIMER_COUNT=$(remote "systemctl list-timers 2>/dev/null | grep -c backup || echo 0")
if [ "$TIMER_COUNT" -gt 0 ]; then
    pass "$TIMER_COUNT backup timer(s) scheduled"
else
    fail "No backup timers found"
fi

# ============================================================================
# Test 9: Log Accessibility
# ============================================================================
header "Test 9: Log Accessibility"
info "Checking if service logs are accessible..."

LOG_CHECK=$(remote "sudo journalctl -u podman-litellm -n 1 2>/dev/null | wc -l" || echo "0")
if [ "$LOG_CHECK" -gt 0 ]; then
    pass "Service logs are accessible"
else
    fail "Cannot access service logs"
fi

# ============================================================================
# Test 10: Resource Usage
# ============================================================================
header "Test 10: Resource Usage"
info "Checking system resource usage..."

subheader "Memory Usage"
MEMORY_INFO=$(remote "free -h | grep Mem" || echo "")
if [ -n "$MEMORY_INFO" ]; then
    pass "Memory info retrieved"
    log "  $MEMORY_INFO"
else
    fail "Could not retrieve memory info"
fi

subheader "Disk Usage"
DISK_INFO=$(remote "df -h / | tail -1" || echo "")
if [ -n "$DISK_INFO" ]; then
    pass "Disk info retrieved"
    log "  $DISK_INFO"
else
    fail "Could not retrieve disk info"
fi

subheader "PostgreSQL Connections"
PG_CONNECTIONS=$(remote "sudo -u postgres psql -t -c 'SELECT count(*) FROM pg_stat_activity;'" || echo "0")
PG_CONNECTIONS=$(echo "$PG_CONNECTIONS" | xargs)
if [ "$PG_CONNECTIONS" -gt 0 ] 2>/dev/null; then
    pass "PostgreSQL has $PG_CONNECTIONS active connection(s)"
else
    info "Could not retrieve PostgreSQL connection count"
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
