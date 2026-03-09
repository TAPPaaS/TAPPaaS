#!/usr/bin/env bash
#
# TAPPaaS OpenWebUI Health & Regression Test
#
# Validates that the OpenWebUI module is running correctly by checking
# SSH connectivity, container status, HTTP endpoint, PostgreSQL, and Redis.
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh openwebui
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0

# ── Helper functions ──────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Run health and regression checks for the OpenWebUI module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} openwebui
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

check_container() {
    info "Check 2: OpenWebUI container is running"
    local status
    # shellcheck disable=SC2086
    status=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo podman ps --filter name=openwebui --format '{{.Status}}'" 2>/dev/null) || true
    if [[ "${status}" == *"Up"* ]]; then
        check_pass "Container is running (${status})"
    else
        check_fail "Container is not running (status: ${status:-not found})"
    fi
}

check_http() {
    info "Check 3: HTTP health check on port 8080"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/" 2>/dev/null) || true
    if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
        check_pass "HTTP responding (status ${http_code})"
    else
        check_fail "HTTP not responding (status: ${http_code:-timeout})"
    fi
}

check_postgresql() {
    info "Check 4: PostgreSQL accepting connections"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "pg_isready -h 127.0.0.1 -p 5432 -U openwebui -d openwebui" &>/dev/null; then
        check_pass "PostgreSQL is accepting connections"
    else
        check_fail "PostgreSQL is not accepting connections"
    fi
}

check_redis() {
    info "Check 5: Redis responding"
    local pong
    # shellcheck disable=SC2086
    pong=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "redis-cli -h 127.0.0.1 -p 6379 ping" 2>/dev/null) || true
    if [[ "${pong}" == "PONG" ]]; then
        check_pass "Redis is responding"
    else
        check_fail "Redis is not responding (got: ${pong:-no response})"
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

    info "=== OpenWebUI Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_ssh
    check_container
    check_http
    check_postgresql
    check_redis

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
