#!/usr/bin/env bash
#
# TAPPaaS logging Health & Regression Test
#
# Validates that the logging stack is running: SSH, Loki ready, Grafana
# responding, Promtail metrics endpoint, and the syslog ingest port open.
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh logging
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
# vmid/zone0 may be overridden to test a non-default instance (issue #196).
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
ZONE0NAME="${TAPPAAS_ZONE0_OVERRIDE:-$(get_config_value 'zone0' 'mgmt')}"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0

# ── Helpers ───────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Run health and regression checks for the logging module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} logging
EOF
}

check_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ── Test functions ────────────────────────────────────────────────────

check_ssh() {
    info "Check 1: SSH connectivity to ${VM_HOST}"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
        check_pass "SSH connection successful"
    else
        check_fail "SSH connection failed to tappaas@${VM_HOST}"
    fi
}

check_loki_ready() {
    info "Check 2: Loki /ready endpoint"
    local body
    # shellcheck disable=SC2086
    body=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 http://127.0.0.1:3100/ready" 2>/dev/null) || true
    if [[ "${body}" == *"ready"* ]]; then
        check_pass "Loki reports ready"
    else
        check_fail "Loki /ready did not return 'ready' (got: ${body:-no response})"
    fi
}

check_loki_metrics() {
    info "Check 3: Loki /metrics endpoint"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3100/metrics" 2>/dev/null) || true
    if [[ "${http_code}" == "200" ]]; then
        check_pass "Loki metrics responding"
    else
        check_fail "Loki metrics not responding (status: ${http_code:-timeout})"
    fi
}

check_grafana_http() {
    info "Check 4: Grafana login page"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3000/login" 2>/dev/null) || true
    if [[ "${http_code}" =~ ^(200|302)$ ]]; then
        check_pass "Grafana login responding (status ${http_code})"
    else
        check_fail "Grafana login not responding (status: ${http_code:-timeout})"
    fi
}

check_grafana_health() {
    info "Check 5: Grafana /api/health"
    local body
    # shellcheck disable=SC2086
    body=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 http://127.0.0.1:3000/api/health" 2>/dev/null) || true
    if [[ "${body}" == *"\"database\":"*"\"ok\""* ]]; then
        check_pass "Grafana health: database ok"
    else
        check_fail "Grafana health unexpected (got: ${body:-no response})"
    fi
}

check_promtail_metrics() {
    info "Check 6: Promtail metrics endpoint"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9080/metrics" 2>/dev/null) || true
    if [[ "${http_code}" == "200" ]]; then
        check_pass "Promtail metrics responding"
    else
        check_fail "Promtail metrics not responding (status: ${http_code:-timeout})"
    fi
}

check_syslog_port() {
    info "Check 7: Syslog receiver listening on tcp/1514"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "ss -lnt 'sport = :1514' | grep -q LISTEN" &>/dev/null; then
        check_pass "Syslog ingest port 1514/tcp is listening"
    else
        check_fail "Syslog ingest port 1514/tcp is NOT listening"
    fi
}

check_loki_query() {
    info "Check 8: Loki has received at least one log line from the local journal"
    local count
    # The promtail journal scrape ships local journal entries. After a fresh boot
    # there should be at least one stream with job="systemd-journal".
    # shellcheck disable=SC2086
    count=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 --get 'http://127.0.0.1:3100/loki/api/v1/label/job/values' | jq -r '.data | length'" 2>/dev/null) || true
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 1 )); then
        check_pass "Loki has ${count} job label value(s)"
    else
        check_fail "Loki has no log streams yet (got: ${count:-no response})"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    info "=== logging Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_ssh
    check_loki_ready
    check_loki_metrics
    check_grafana_http
    check_grafana_health
    check_promtail_metrics
    check_syslog_port
    check_loki_query

    echo ""
    info "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        error "Health check FAILED — ${FAIL_COUNT} check(s) did not pass"
        exit 1
    fi

    info "${GN}All health checks passed${CL}"
    exit 0
}

main "$@"
