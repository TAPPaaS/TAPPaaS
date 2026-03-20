#!/usr/bin/env bash
#
# TAPPaaS Backup VM Service - Test
#
# Verifies that backup is configured and backups exist for a module's VM.
# Called by test-module.sh for any module that depends on backup:vm.
#
# Tests:
#   1. PBS storage is configured and available on the VM's node (error if not)
#   2. At least one backup exists for the VM (warning if not)
#   Deep mode:
#   3. Most recent backup is less than 48 hours old
#   4. Backup job exists covering this VM
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed (warnings)
#   2  Fatal error (backup not configured)
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 2

VMID="$(get_config_value 'vmid')"
VMNAME="$(get_config_value 'vmname' "${MODULE}")"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
MGMT="mgmt"

readonly STORAGE_NAME="tappaas_backup"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0
WARN_COUNT=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { warn "    ⚠ $1"; WARN_COUNT=$((WARN_COUNT + 1)); }

info "  ${BOLD}backup:vm tests for ${BL}${VMNAME}${CL} (VMID ${VMID} on ${NODE})"

# Find a reachable Proxmox node to query
QUERY_NODE=""
for candidate in "${NODE}" $(get_all_node_hostnames); do
    candidate_fqdn="${candidate}.${MGMT}.internal"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${candidate_fqdn}" "true" &>/dev/null; then
        QUERY_NODE="${candidate}"
        break
    fi
done

if [[ -z "${QUERY_NODE}" ]]; then
    error "    No Proxmox nodes reachable"
    exit 2
fi

QUERY_FQDN="${QUERY_NODE}.${MGMT}.internal"

# ── Test 1: PBS storage is configured and available ──────────────────

info "  Check 1: PBS storage '${STORAGE_NAME}' configured on ${NODE}"

storage_status=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
    "root@${QUERY_FQDN}" \
    "pvesm status --storage ${STORAGE_NAME} 2>/dev/null" 2>/dev/null) || true

if [[ -n "${storage_status}" ]] && echo "${storage_status}" | grep -q "${STORAGE_NAME}"; then
    # Check if the storage is active (pvesm status columns: Name Type Status ...)
    storage_active=$(echo "${storage_status}" | grep "${STORAGE_NAME}" | awk '{print $3}') || true
    if [[ "${storage_active}" == "active" ]]; then
        pass "PBS storage '${STORAGE_NAME}' is configured and active"
    else
        fail "PBS storage '${STORAGE_NAME}' exists but is not active (status: ${storage_active:-unknown})"
        info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${WARN_COUNT} warnings${CL}"
        exit 2
    fi
else
    fail "PBS storage '${STORAGE_NAME}' is not configured on node ${NODE}"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${WARN_COUNT} warnings${CL}"
    exit 2
fi

# ── Test 2: At least one backup exists for this VM ───────────────────

info "  Check 2: Backup exists for VMID ${VMID}"

backup_list=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
    "root@${QUERY_FQDN}" \
    "pvesh get /nodes/${QUERY_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID} --content backup --output-format json" 2>/dev/null) || true

backup_count=0
if [[ -n "${backup_list}" ]]; then
    backup_count=$(echo "${backup_list}" | jq 'length' 2>/dev/null) || true
    backup_count="${backup_count:-0}"
fi

if [[ "${backup_count}" -gt 0 ]]; then
    pass "Found ${backup_count} backup(s) for VMID ${VMID}"
else
    skip "No backups found for VMID ${VMID} — has the first backup run yet?"
fi

# ── Deep mode tests ──────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 3: Most recent backup age
    info "  Check 3: Most recent backup age"
    if [[ "${backup_count}" -gt 0 ]]; then
        # Get the most recent backup timestamp (ctime = creation time, epoch)
        latest_ctime=$(echo "${backup_list}" | jq '[.[] | .ctime // 0] | max' 2>/dev/null) || true
        if [[ -n "${latest_ctime}" && "${latest_ctime}" -gt 0 ]]; then
            now=$(date +%s)
            age_hours=$(( (now - latest_ctime) / 3600 ))
            if [[ "${age_hours}" -lt 48 ]]; then
                pass "Most recent backup is ${age_hours}h old (within 48h)"
            else
                skip "Most recent backup is ${age_hours}h old (older than 48h)"
            fi
        else
            skip "Could not determine backup age"
        fi
    else
        skip "No backups to check age for"
    fi

    # Test 4: Backup job covers this VM
    info "  Check 4: Backup job exists for VMID ${VMID}"
    backup_jobs=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${QUERY_FQDN}" \
        "pvesh get /cluster/backup --output-format json" 2>/dev/null) || true

    job_found=false
    if [[ -n "${backup_jobs}" ]]; then
        # Check if any job covers this VM (either --all or explicit vmid list)
        job_found=$(echo "${backup_jobs}" | jq -r \
            --argjson vmid "${VMID}" \
            '[.[] | select(.all == 1 or (.vmid // "" | split(",") | map(tonumber? // empty) | any(. == $vmid)))] | length > 0' \
            2>/dev/null) || true
    fi

    if [[ "${job_found}" == "true" ]]; then
        pass "Backup job covers VMID ${VMID}"
    else
        skip "No backup job found covering VMID ${VMID}"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${WARN_COUNT} warnings${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
