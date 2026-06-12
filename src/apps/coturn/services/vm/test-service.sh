#!/usr/bin/env bash
#
# TAPPaaS coturn VM Service - Test
#
# Verifies coturn is reachable and serving TURN/STUN for a consuming module.
# Called by test-module.sh for any module that depends on coturn:vm.
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
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
readonly COTURN_JSON="${CONFIG_DIR}/coturn.json"

if [[ ! -f "${COTURN_JSON}" ]]; then
    error "coturn config not found: ${COTURN_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}coturn:vm tests for ${BL}${MODULE}${CL}"

# ── Test 1: TCP port 3478 reachable ──────────────────────────────────

info "  Check 1: coturn TCP 3478 reachable at ${VMNAME}.${ZONE}.internal"
if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    pass "coturn responding on TCP 3478"
else
    fail "coturn not responding on TCP 3478 at ${VMNAME}.${ZONE}.internal"
fi

# ── Test 2: coturn service active on VM ──────────────────────────────

info "  Check 2: coturn.service is active"
STATUS=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "tappaas@${VMNAME}.${ZONE}.internal" \
    "systemctl is-active coturn 2>/dev/null" 2>/dev/null || echo "unknown")
if [[ "${STATUS}" == "active" ]]; then
    pass "coturn.service is active"
else
    fail "coturn.service is ${STATUS}"
fi

# ── Summary ──────────────────────────────────────────────────────────

info "  Results: ${PASS} passed, ${FAIL} failed"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
