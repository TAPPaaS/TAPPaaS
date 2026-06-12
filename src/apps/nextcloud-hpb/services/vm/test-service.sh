#!/usr/bin/env bash
#
# TAPPaaS nextcloud-hpb VM Service - Test
#
# Verifies the HPB is reachable and serving its stats endpoint for a consuming module.
# Called by test-module.sh for any module that depends on nextcloud-hpb:vm.
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

readonly HPB_JSON="/home/tappaas/config/nextcloud-hpb.json"

if [[ ! -f "${HPB_JSON}" ]]; then
    error "nextcloud-hpb config not found: ${HPB_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname' "${HPB_JSON}")
ZONE=$(jq -r '.zone0' "${HPB_JSON}")

PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}nextcloud-hpb:vm tests for ${BL}${MODULE}${CL}"

# ── Test 1: TCP port 8080 reachable ──────────────────────────────────

info "  Check 1: nextcloud-hpb TCP 8080 reachable at ${VMNAME}.${ZONE}.internal"
if nc -z -w5 "${VMNAME}.${ZONE}.internal" 8080 2>/dev/null; then
    pass "nextcloud-hpb responding on TCP 8080"
else
    fail "nextcloud-hpb not responding on TCP 8080 at ${VMNAME}.${ZONE}.internal"
fi

# ── Test 2: Stats endpoint returns valid JSON ─────────────────────────

info "  Check 2: /api/v1/stats endpoint"
STATS=$(curl -sf --max-time 10 "http://${VMNAME}.${ZONE}.internal:8080/api/v1/stats" 2>/dev/null || true)
if echo "${STATS}" | grep -q '"currentSessionsTotal"'; then
    pass "HPB stats endpoint returned valid JSON"
else
    fail "HPB stats endpoint did not return expected JSON"
fi

# ── Test 3: nextcloud-spreed-signaling service active ────────────────

info "  Check 3: nextcloud-spreed-signaling.service is active"
STATUS=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "tappaas@${VMNAME}.${ZONE}.internal" \
    "systemctl is-active nextcloud-spreed-signaling 2>/dev/null" 2>/dev/null || echo "unknown")
if [[ "${STATUS}" == "active" ]]; then
    pass "nextcloud-spreed-signaling.service is active"
else
    fail "nextcloud-spreed-signaling.service is ${STATUS}"
fi

# ── Summary ──────────────────────────────────────────────────────────

info "  Results: ${PASS} passed, ${FAIL} failed"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
