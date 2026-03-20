#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Test
#
# Verifies that a module's VM is running and reachable.
# Called by test-module.sh for any module that depends on cluster:vm.
#
# Tests:
#   1. VM is running in Proxmox (qm status)
#   2. VM responds to ping
#   3. SSH connectivity from tappaas-cicd
#   Deep mode:
#   4. Root filesystem usage below 95%
#   5. Available memory above 50MB
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error (VM not running or unreachable)
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 2

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
MGMT="mgmt"

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"

# Firewall VM only supports root access (no tappaas user)
if [[ "${VMNAME}" == "firewall" ]]; then
    SSH_USER="root"
else
    SSH_USER="tappaas"
fi

readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}cluster:vm tests for ${BL}${VMNAME}${CL} (VMID ${VMID} on ${NODE})"

# ── Test 1: VM is running in Proxmox ────────────────────────────────

info "  Check 1: VM status in Proxmox"

# Query cluster API to find VM status regardless of which node it's on
vm_status=""
for node_candidate in "${NODE}" $(get_all_node_hostnames); do
    candidate_fqdn="${node_candidate}.${MGMT}.internal"
    vm_status=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${candidate_fqdn}" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .status // empty' 2>/dev/null) || true
    if [[ -n "${vm_status}" ]]; then
        break
    fi
done

if [[ "${vm_status}" == "running" ]]; then
    pass "VM is running"
else
    fail "VM is not running (status: ${vm_status:-unknown})"
    # Fatal — no point testing further if VM isn't running
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 2
fi

# ── Test 2: Ping ────────────────────────────────────────────────────

info "  Check 2: Ping ${VM_HOST}"
if ping -c 1 -W 5 "${VM_HOST}" &>/dev/null; then
    pass "Ping successful"
else
    fail "Ping failed to ${VM_HOST}"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 2
fi

# ── Test 3: SSH connectivity ────────────────────────────────────────

info "  Check 3: SSH connectivity"
# shellcheck disable=SC2086
if ssh ${SSH_OPTS} "${SSH_USER}@${VM_HOST}" "exit 0" &>/dev/null; then
    pass "SSH connection successful"
else
    fail "SSH connection failed to ${SSH_USER}@${VM_HOST}"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 2
fi

# ── Deep mode tests ─────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 4: Disk space
    # Use POSIX-compatible df (FreeBSD/OPNsense lacks GNU --output=pcent)
    info "  Check 4: Root filesystem usage"
    # shellcheck disable=SC2086
    disk_pct=$(ssh ${SSH_OPTS} "${SSH_USER}@${VM_HOST}" \
        "df / | tail -1 | awk '{gsub(/%/,\"\",\$5); print \$5}'" 2>/dev/null) || true
    if [[ -n "${disk_pct}" && "${disk_pct}" -lt 95 ]]; then
        pass "Disk usage at ${disk_pct}% (below 95%)"
    else
        fail "Disk usage critical: ${disk_pct:-unknown}%"
    fi

    # Test 5: Available memory
    # FreeBSD/OPNsense has no /proc/meminfo; use sysctl for free+inactive pages
    info "  Check 5: Available memory"
    # shellcheck disable=SC2086
    if [[ "${VMNAME}" == "firewall" ]]; then
        # OPNsense default shell is opnsense-shell; must invoke /bin/sh explicitly
        mem_avail_mb=$(ssh ${SSH_OPTS} "${SSH_USER}@${VM_HOST}" \
            "/bin/sh -c 'expr \( \$(sysctl -n vm.stats.vm.v_free_count) + \$(sysctl -n vm.stats.vm.v_inactive_count) \) \* \$(sysctl -n hw.pagesize) / 1048576'" 2>/dev/null) || true
    else
        mem_avail_mb=$(ssh ${SSH_OPTS} "${SSH_USER}@${VM_HOST}" \
            "awk '/MemAvailable/ {printf \"%d\", \$2/1024}' /proc/meminfo" 2>/dev/null) || true
    fi
    if [[ -n "${mem_avail_mb}" && "${mem_avail_mb}" -gt 50 ]]; then
        pass "Available memory: ${mem_avail_mb}MB"
    else
        fail "Available memory critically low: ${mem_avail_mb:-unknown}MB"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
