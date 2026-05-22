#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant Module Tests
#
# Tests:
#   1. VM is running (via qm status on Proxmox node)
#   2. HAOS web UI reachable on port 8123 (HTTP 200 or 302)
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh homeassistant
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local result="$2"
    if [[ "${result}" == "pass" ]]; then
        info "  ${GN}PASS${CL} ${name}"
        PASS=$((PASS + 1))
    else
        error "  FAIL ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
info "${BOLD}Testing: ${VMNAME} (VMID: ${VMID}) on ${NODE}${CL}"

# Test 1: VM is running
VM_STATUS="$(ssh -o StrictHostKeyChecking=no "root@${NODE}.mgmt.internal" "qm status ${VMID}" 2>/dev/null || echo "error")"
if echo "${VM_STATUS}" | grep -q "status: running"; then
    run_test "VM is running" "pass"
else
    run_test "VM is running (got: ${VM_STATUS})" "fail"
fi

# Test 2: HAOS web UI responds on port 8123
VM_IP="$(ssh -o StrictHostKeyChecking=no "root@${NODE}.mgmt.internal" \
    "qm agent ${VMID} network-get-interfaces 2>/dev/null | python3 -c \"
import json,sys
ifaces=json.load(sys.stdin)
for i in ifaces:
  for a in i.get('ip-addresses',[]):
    if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith('127') and not a['ip-address'].startswith('172'):
      print(a['ip-address']); exit()
\"" 2>/dev/null || echo "")"

if [[ -n "${VM_IP}" ]]; then
    HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${VM_IP}:8123" 2>/dev/null || echo "000")"
    if [[ "${HTTP_CODE}" == "200" ]] || [[ "${HTTP_CODE}" == "302" ]]; then
        run_test "HAOS web UI reachable at http://${VM_IP}:8123 (HTTP ${HTTP_CODE})" "pass"
    else
        run_test "HAOS web UI at http://${VM_IP}:8123 (HTTP ${HTTP_CODE})" "fail"
    fi
else
    run_test "HAOS web UI (could not get VM IP)" "fail"
fi

# Summary
echo ""
info "${BOLD}Results: ${PASS} passed, ${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
