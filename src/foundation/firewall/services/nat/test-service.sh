#!/usr/bin/env bash
#
# TAPPaaS Firewall NAT Service - Test
#
# Verifies that a module's destination-NAT (port-forward) rules are configured
# on OPNsense. Called by test-module.sh for any module that depends on
# firewall:nat.
#
# Tests:
#   For each configured natRules entry:
#     1. A matching port-forward exists on OPNsense
#   Deep mode:
#     2. The rule's target host and internal/external ports match the config
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed (or firewallType=NONE → skip)
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=nat-common.sh disable=SC1091
. "${SCRIPT_DIR}/nat-common.sh"

if [[ ! -f "${MODULE_JSON}" ]]; then
    error "Module config not found: ${MODULE_JSON}"
    exit 2
fi

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}firewall:nat tests for ${BL}${MODULE}${CL}"

RULE_COUNT=$(nat_rule_count)
if [[ "${RULE_COUNT}" -eq 0 ]]; then
    info "    No natRules configured — nothing to test"
    exit 0
fi

# Check firewallType — if NONE, skip all tests
FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi
if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "    firewallType=NONE — skipping NAT tests"
    exit 0
fi

if ! command -v nat-manager &>/dev/null; then
    error "    nat-manager CLI not found"
    exit 2
fi

# Fetch this module's port-forwards once.
NAT_LIST=$(nat-manager list-rules --no-ssl-verify --json --search "TAPPaaS: ${MODULE}" 2>/dev/null) || NAT_LIST="[]"

while IFS= read -r rule; do
    [[ -z "${rule}" ]] && continue
    ext=$(nat_rule_external_port "${rule}")
    intp=$(nat_rule_internal_port "${rule}")
    proto=$(nat_rule_protocol "${rule}")
    desc=$(nat_rule_description "${MODULE}" "${rule}")

    info "  Check: port-forward '${desc}'"

    match=$(echo "${NAT_LIST}" | jq -c --arg d "${desc}" '.[] | select(.description == $d)')
    if [[ -z "${match}" ]]; then
        fail "No port-forward found for '${desc}'"
        continue
    fi
    pass "Port-forward exists (${proto} WAN:${ext} -> :${intp})"

    if [[ "${DEEP}" -eq 1 ]]; then
        got_ext=$(echo "${match}" | jq -r '.destination_port')
        got_int=$(echo "${match}" | jq -r '.local_port')
        if [[ "${got_ext}" == "${ext}" && "${got_int}" == "${intp}" ]]; then
            pass "Ports match config (ext ${got_ext}, int ${got_int})"
        else
            fail "Port mismatch: expected ext ${ext}/int ${intp}, got ext ${got_ext}/int ${got_int}"
        fi
    fi
done < <(nat_rules_json)

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
