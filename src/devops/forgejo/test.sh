#!/usr/bin/env bash
#
# forgejo — test
#
# Verifies that the Forgejo VM is running and all key services are reachable.
# Supports TAPPAAS_VMID_OVERRIDE and TAPPAAS_ZONE0_OVERRIDE for multi-instance testing.
#
# Usage: test.sh [vmname]
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-forgejo}" 2>/dev/null || true

VMNAME="$(get_config_value 'vmname' "${1:-forgejo}")"
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
ZONE0NAME="${TAPPAAS_ZONE0_OVERRIDE:-$(get_config_value 'zone0' 'srvWork')}"
VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

PASS=0; FAIL=0; SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

echo ""
echo "Forgejo test — ${VMNAME} (VMID: ${VMID}, zone: ${ZONE0NAME})"
echo "─────────────────────────────────────────────────────────────"

# ── Test 1: VM is running ─────────────────────────────────────────────────────
echo ""
echo "[ Infrastructure ]"

if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" true 2>/dev/null; then
    pass "VM is running and SSH is reachable"
else
    fail "VM not reachable via SSH at ${VM_HOST}"
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
    exit 1
fi

# ── Test 2: Disk usage ────────────────────────────────────────────────────────
DISK_USAGE=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "df / --output=pcent | tail -1 | tr -d ' %'" 2>/dev/null || echo "UNKNOWN")
if [[ "${DISK_USAGE}" != "UNKNOWN" && "${DISK_USAGE}" -lt 85 ]]; then
    pass "Disk usage ${DISK_USAGE}% (< 85%)"
else
    fail "Disk usage ${DISK_USAGE}% — check available space"
fi

# ── Test 3: Memory ────────────────────────────────────────────────────────────
MEM_FREE=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo" 2>/dev/null || echo "0")
if [[ "${MEM_FREE}" -gt 256 ]]; then
    pass "Memory available: ${MEM_FREE} MB"
else
    fail "Low memory: only ${MEM_FREE} MB available"
fi

# ── Test 4: Forgejo service active ────────────────────────────────────────────
echo ""
echo "[ Forgejo service ]"

SVC_STATUS=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "systemctl is-active forgejo 2>/dev/null || echo inactive")
if [[ "${SVC_STATUS}" == "active" ]]; then
    pass "Forgejo systemd service is active"
else
    fail "Forgejo service state: ${SVC_STATUS}"
fi

# ── Test 5: Web UI port 3000 ──────────────────────────────────────────────────
if nc -zv -w 5 "${VM_HOST}" 3000 2>&1 | grep -q "succeeded"; then
    pass "Web UI reachable on TCP 3000"
else
    fail "Web UI NOT reachable on TCP 3000 — check forgejo service and firewall"
fi

# ── Test 6: HTTP response ─────────────────────────────────────────────────────
HTTP_CODE=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
    pass "Forgejo HTTP response: ${HTTP_CODE}"
else
    fail "Forgejo HTTP response: ${HTTP_CODE} (expected 200 or 302)"
fi

# ── Test 7: API health endpoint ───────────────────────────────────────────────
API_RESP=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "curl -sf http://localhost:3000/api/healthz 2>/dev/null | grep -o '\"status\"[[:space:]]*:[[:space:]]*\"pass\"' || echo FAIL")
if [[ "${API_RESP}" == *"pass"* ]]; then
    pass "Forgejo API /healthz: pass"
else
    fail "Forgejo API /healthz did not return status:pass (got: ${API_RESP})"
fi

# ── Test 8: SSH port 22 ───────────────────────────────────────────────────────
if nc -zv -w 5 "${VM_HOST}" 22 2>&1 | grep -q "succeeded"; then
    pass "SSH git port 22 reachable"
else
    fail "SSH git port 22 NOT reachable"
fi

# ── Test 9: Repository data directory ────────────────────────────────────────
REPO_DIR=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "sudo test -d /var/lib/forgejo/repositories && echo OK || echo MISSING" 2>/dev/null)
if [[ "${REPO_DIR}" == "OK" ]]; then
    pass "Repository data directory exists: /var/lib/forgejo/repositories"
else
    fail "Repository data directory missing: /var/lib/forgejo/repositories"
fi

# ── Test 10: Backup timer scheduled ───────────────────────────────────────────
TIMER_STATE=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
    "systemctl is-active forgejo-backup.timer 2>/dev/null || echo inactive")
if [[ "${TIMER_STATE}" == "active" ]]; then
    pass "Backup timer (forgejo-backup.timer) is active"
else
    fail "Backup timer NOT active: ${TIMER_STATE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[[ "${FAIL}" -eq 0 ]] || exit 1
