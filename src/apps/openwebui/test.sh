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

# ── Parse arguments ───────────────────────────────────────────────────
# Usage: ./test.sh [vmname] [--vmid <id>] [--zone0 <zone>]
_MODULE="${1:-openwebui}"
# Seed overrides from the env vars exported by test-module.sh (issue #196);
# explicit --vmid/--zone0 args below take precedence.
_OVERRIDE_VMID="${TAPPAAS_VMID_OVERRIDE:-}"
_OVERRIDE_ZONE="${TAPPAAS_ZONE0_OVERRIDE:-}"

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)  _OVERRIDE_VMID="$2"; shift 2 ;;
    --zone0) _OVERRIDE_ZONE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# shellcheck source=../../foundation/tappaas-cicd/lib/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh "${_MODULE}" 2>/dev/null || true

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${_MODULE}")"
VMID="${_OVERRIDE_VMID:-$(get_config_value 'vmid')}"
ZONE0NAME="${_OVERRIDE_ZONE:-$(get_config_value 'zone0' 'mgmt')}"
EXPECTED_VERSION="$(get_config_value 'appVersion')"
readonly VMNAME VMID ZONE0NAME EXPECTED_VERSION

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0

# ── Helper functions ──────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [vmname] [--vmid <id>] [--zone0 <zone>]

Run health checks for the OpenWebUI module. Defaults to config in /home/tappaas/config/openwebui.json.

Options:
    --vmid <id>     Override VMID from config
    --zone0 <zone>  Override zone from config

Examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} openwebui
    ${SCRIPT_NAME} openwebui --vmid 313 --zone0 srv-cust
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

# Advisory only — does not affect PASS_COUNT/FAIL_COUNT or exit code.
# Use for conditions that are expected/benign in some valid call contexts
# (e.g. version mismatch is expected pre-update, since the deployed VM still
# runs the old version right up until nixos-rebuild actually applies the new
# config) but still worth surfacing.
check_warn() {
    warn "  ⚠ $1"
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
    local status i
    # RETRY, like check_http below. A single probe here made this check race the
    # container's own creation and fail a perfectly healthy deploy: on 0.11.2 the
    # wrapper's ExecStartPre now runs the DB migration in a throwaway container
    # BEFORE creating the app container (see openwebui.nix), so `podman ps` can
    # legitimately report nothing for ~30-60s after the unit starts.
    #
    # This was not theoretical — it rolled back two good 0.11.2 deployments on
    # 2026-08-31. The tell was that Check 2 reported "not found" while Check 2b,
    # running the SAME `podman ps` moments later, successfully read the image
    # name and Check 3 got HTTP 200 on attempt 12/15. A check that disagrees with
    # its own neighbours is measuring timing, not health.
    #
    # --filter name= is a SUBSTRING match, so it would also match the transient
    # `openwebui-migrate` container; the --format output is filtered to the exact
    # name to keep the two from being confused.
    for i in $(seq 1 15); do
        # shellcheck disable=SC2086
        status=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
            "sudo podman ps --filter name=openwebui --format '{{.Names}}\t{{.Status}}' \
             | awk -F'\t' '\$1==\"openwebui\"{print \$2}'" 2>/dev/null) || true
        [[ "${status}" == *"Up"* ]] && break
        [[ $i -lt 15 ]] && sleep 4
    done
    if [[ "${status}" == *"Up"* ]]; then
        check_pass "Container is running (${status})"
    else
        check_fail "Container is not running (status: ${status:-not found})"
    fi
}

check_version() {
    info "Check 2b: Container image matches configured version (${EXPECTED_VERSION:-unset})"
    if [[ -z "${EXPECTED_VERSION}" ]]; then
        check_fail "appVersion not found in config — cannot verify running image version"
        return
    fi
    local image
    # shellcheck disable=SC2086
    image=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo podman ps --filter name=openwebui --format '{{.Image}}'" 2>/dev/null) || true
    if [[ "${image}" == *":${EXPECTED_VERSION}" ]]; then
        check_pass "Running image matches configured version (${image})"
    else
        check_warn "Running image (${image:-not found}) does not match configured appVersion ${EXPECTED_VERSION} — expected pre-update (old version still running); should read as a real problem only after an update completes"
    fi
}

check_http() {
    info "Check 3: HTTP health check on port 8080"
    # After a NixOS rebuild + reboot the OpenWebUI container takes a few seconds
    # to start serving HTTP, so the very first probe can miss it (#138). Retry up
    # to 15 times over ~60s before declaring failure — widened 2026-07-02 after
    # the 0.10.2 upgrade's real container needed longer than the original ~10s
    # window (larger image / possible startup migration work on a bigger
    # version bump), which triggered a false-failure rollback on an otherwise
    # successful update.
    local http_code attempt max_attempts=15
    for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
        # shellcheck disable=SC2086
        http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/" 2>/dev/null) || true
        if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
            check_pass "HTTP responding (status ${http_code}, attempt ${attempt}/${max_attempts})"
            return
        fi
        if (( attempt < max_attempts )); then
            sleep 4
        fi
    done
    check_fail "HTTP not responding after ${max_attempts} attempts (last status: ${http_code:-timeout})"
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

    # vmname is optional — defaults to 'openwebui' from config

    info "=== OpenWebUI Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_ssh
    check_container
    check_version
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
