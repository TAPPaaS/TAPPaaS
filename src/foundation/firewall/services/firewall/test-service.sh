#!/usr/bin/env bash
#
# TAPPaaS Firewall Service - Test
#
# Verifies that a module's per-module firewall rules are configured on
# OPNsense. Called by test-module.sh for any module that depends on
# firewall:firewall.
#
# Tests:
#   1. Module declares firewall rules (ingress/egress in module.json)
#   2. firewall-rules-manager reports all declared rules as present
#   Deep mode:
#   3. Each declared ingress port is reachable from its source zone
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed (or firewallType=NONE -> skip)
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

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

if [[ ! -f "${MODULE_JSON}" ]]; then
    error "Module config not found: ${MODULE_JSON}"
    exit 2
fi

# Check firewallType -- if NONE, skip all tests
FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

pass() { info "    ${GN}OK${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    FAIL $1"; FAIL=$((FAIL + 1)); }

# Resolve module details
VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
INGRESS_COUNT=$(jq -r '(.ingress // []) | length' "${MODULE_JSON}")
EGRESS_COUNT=$(jq -r '(.egress // []) | length' "${MODULE_JSON}")

info "  ${BOLD}firewall:firewall tests for ${BL}${MODULE}${CL}"
info "    Zone: ${ZONE}, ingress: ${INGRESS_COUNT}, egress: ${EGRESS_COUNT}"

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "    firewallType=NONE -- skipping firewall tests"
    exit 0
fi

# Verify firewall-rules-manager is available
if ! command -v firewall-rules-manager &>/dev/null; then
    error "    firewall-rules-manager CLI not found"
    exit 2
fi

# -- Test 1: Module declares firewall rules ---------------------------

info "  Check 1: Module declares firewall rules"
if [[ "${INGRESS_COUNT}" -eq 0 && "${EGRESS_COUNT}" -eq 0 ]]; then
    pass "Module declares no firewall rules -- nothing to verify"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 0
else
    pass "Module declares ${INGRESS_COUNT} ingress + ${EGRESS_COUNT} egress rule(s)"
fi

# -- Test 2: All declared rules present in OPNsense -------------------

info "  Check 2: Declared rules present in OPNsense"
if firewall-rules-manager verify-rules "${MODULE}" \
        --config-dir "${CONFIG_DIR}" \
        --no-ssl-verify; then
    pass "All declared rules present in OPNsense"
else
    fail "One or more declared rules missing from OPNsense"
fi

# -- Deep mode tests --------------------------------------------------

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 3: ingress ports reachable from their source zone
    info "  Check 3: Ingress port reachability (deep)"
    UPSTREAM="${VMNAME}.${ZONE}.internal"

    # Iterate declared ingress ports and probe each from tappaas-cicd.
    # A connection refused/timeout on a port that should be open is a fail;
    # any TCP response (even auth-required) is a pass.
    while read -r port; do
        [[ -z "${port}" ]] && continue
        if timeout 5 bash -c "echo > /dev/tcp/${UPSTREAM}/${port}" 2>/dev/null; then
            pass "Port ${port} reachable on ${UPSTREAM}"
        else
            fail "Port ${port} not reachable on ${UPSTREAM}"
        fi
    done < <(jq -r '(.ingress // [])[] | .ports[]' "${MODULE_JSON}" | sort -u)
fi

# -- Summary ----------------------------------------------------------

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
