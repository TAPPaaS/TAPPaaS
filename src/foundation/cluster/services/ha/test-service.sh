#!/usr/bin/env bash
#
# TAPPaaS Cluster HA Service - Test
#
# Verifies that a module's HA configuration is correct and healthy.
# Called by test-module.sh for any module that depends on cluster:ha.
#
# Tests:
#   1. HA resource exists and is in 'started' state
#   2. Node-affinity rule exists with correct nodes
#   Deep mode:
#   3. Replication job exists for the VM
#   4. Last replication sync succeeded (no errors)
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed (or HANode=NONE → skip)
#   1  One or more checks failed
#   2  Fatal error
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
NODE="$(get_config_value 'node' 'tappaas1')"
HANODE="$(get_config_value 'HANode' 'NONE')"
MGMT="mgmt"

HA_RULE_NAME="ha-${MODULE}"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}cluster:ha tests for ${BL}${MODULE}${CL} (VMID ${VMID})"

# If HANode is NONE, HA is intentionally not configured — nothing to test
if [[ "${HANODE}" == "NONE" || -z "${HANODE}" ]]; then
    info "    HANode is NONE — HA not configured, skipping tests"
    exit 0
fi

info "    Primary: ${NODE}, HA: ${HANODE}"

# Find a reachable Proxmox node to query
QUERY_NODE=""
for candidate in "${NODE}" "${HANODE}" tappaas1 tappaas2 tappaas3; do
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

# ── Test 1: HA resource exists and is started ───────────────────────

info "  Check 1: HA resource status"
ha_output=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
    "root@${QUERY_FQDN}" "ha-manager status" 2>/dev/null) || true

ha_line=$(echo "${ha_output}" | grep "vm:${VMID}" || true)

if [[ -n "${ha_line}" ]]; then
    # Format: "service vm:130 (tappaas1, started)" — extract state without trailing paren
    ha_state=$(echo "${ha_line}" | grep -oP ',\s*\K[a-z]+' || true)
    if [[ "${ha_state}" == "started" ]]; then
        pass "HA resource vm:${VMID} is started"
    else
        fail "HA resource vm:${VMID} state is '${ha_state}' (expected 'started')"
    fi
else
    fail "VM ${VMID} is not in HA resources"
fi

# ── Test 2: Node-affinity rule ──────────────────────────────────────

info "  Check 2: Node-affinity rule"
# Use the API for structured output instead of ha-manager CLI tables
rules_json=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
    "root@${QUERY_FQDN}" \
    "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null) || true

rule_nodes=$(echo "${rules_json}" | jq -r \
    --arg rule "${HA_RULE_NAME}" \
    '.[] | select(.rule == $rule) | .nodes // empty' 2>/dev/null) || true

if [[ -n "${rule_nodes}" ]]; then
    has_primary=$(echo "${rule_nodes}" | grep -c "${NODE}" || true)
    has_ha=$(echo "${rule_nodes}" | grep -c "${HANODE}" || true)
    if [[ "${has_primary}" -gt 0 && "${has_ha}" -gt 0 ]]; then
        pass "HA rule '${HA_RULE_NAME}' has both nodes (${rule_nodes})"
    else
        fail "HA rule '${HA_RULE_NAME}' missing expected nodes (want: ${NODE}, ${HANODE}, got: ${rule_nodes})"
    fi
else
    fail "HA rule '${HA_RULE_NAME}' not found"
fi

# ── Deep mode tests ─────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 3: Replication job exists
    info "  Check 3: Replication job"
    repl_jobs=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${QUERY_FQDN}" \
        "pvesh get /cluster/replication --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" '.[] | select(.guest == $id) | .id' 2>/dev/null) || true

    if [[ -n "${repl_jobs}" ]]; then
        pass "Replication job exists: ${repl_jobs}"
    else
        fail "No replication job found for VMID ${VMID}"
    fi

    # Test 4: Replication health
    info "  Check 4: Replication status"
    if [[ -n "${repl_jobs}" ]]; then
        repl_status=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
            "root@${QUERY_FQDN}" \
            "pvesh get /cluster/replication --output-format json" 2>/dev/null \
            | jq -r --argjson id "${VMID}" \
                '.[] | select(.guest == $id) | .error // empty' 2>/dev/null) || true

        if [[ -z "${repl_status}" ]]; then
            pass "Replication healthy (no errors)"
        else
            fail "Replication error: ${repl_status}"
        fi
    else
        fail "Cannot check replication health — no job found"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
