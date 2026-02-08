#!/usr/bin/env bash
# TAPPaaS HA VM Test Script
#
# Tests that a VM with HA configuration is working correctly
# Usage: ./test-ha.sh <vmname>
# Example: ./test-ha.sh test-nixos-ha

. /home/tappaas/bin/common-install-routines.sh

if [ -z "$1" ]; then
    echo "Usage: ./test-ha.sh <vmname>"
    echo "Example: ./test-ha.sh test-nixos-ha"
    exit 1
fi

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
HANODE="$(get_config_value 'HANode' '')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
REPLICATION_SCHEDULE="$(get_config_value 'replicationSchedule' '*/15')"
STORAGE="$(get_config_value 'storage' 'tanka1')"
MGMT="mgmt"

echo "=============================================="
echo "Testing HA VM: ${VMNAME} (VMID: ${VMID})"
echo "Node: ${NODE}, HA Node: ${HANODE}, Zone: ${ZONE0NAME}"
echo "=============================================="
echo ""

PASS=0
FAIL=0

# Function to report test result
test_result() {
    local test_name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo -e "  [\e[32mPASS\e[0m] $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  [\e[31mFAIL\e[0m] $test_name"
        FAIL=$((FAIL + 1))
    fi
}

echo "Running HA configuration tests..."
echo ""

# Test 1: VM exists and is running
echo "1. VM existence and status test..."
VM_STATUS=$(ssh "root@${NODE}.${MGMT}.internal" "qm status ${VMID}" 2>/dev/null | grep -oP 'status: \K\w+')
if [ "$VM_STATUS" = "running" ]; then
    test_result "VM ${VMID} exists and is running on ${NODE}" 0
else
    test_result "VM ${VMID} exists and is running on ${NODE}" 1
fi

# Test 2: VM is in HA resources
echo "2. HA resource test..."
HA_RESOURCE=$(ssh "root@${NODE}.${MGMT}.internal" "ha-manager config" 2>/dev/null | grep "^vm:${VMID}")
if [ -n "$HA_RESOURCE" ]; then
    test_result "VM ${VMID} is registered in HA resources" 0
else
    test_result "VM ${VMID} is registered in HA resources" 1
fi

# Test 3: HA rule exists
echo "3. HA rule test..."
HA_RULE_NAME="ha-${VMNAME}"
HA_RULE=$(ssh "root@${NODE}.${MGMT}.internal" "ha-manager rules list" 2>/dev/null | grep "${HA_RULE_NAME}")
if [ -n "$HA_RULE" ]; then
    test_result "HA rule '${HA_RULE_NAME}' exists" 0
else
    test_result "HA rule '${HA_RULE_NAME}' exists" 1
fi

# Test 4: Node-affinity rule configuration
echo "4. Node-affinity rule configuration test..."
RULE_CONFIG=$(ssh "root@${NODE}.${MGMT}.internal" "cat /etc/pve/ha/rules.cfg" 2>/dev/null | grep -A 2 "${HA_RULE_NAME}")
if echo "$RULE_CONFIG" | grep -q "nodes ${NODE}:2,${HANODE}:1"; then
    test_result "Node-affinity priorities correct (${NODE}:2, ${HANODE}:1)" 0
else
    test_result "Node-affinity priorities correct (${NODE}:2, ${HANODE}:1)" 1
fi

# Test 5: Replication job exists
echo "5. Replication job test..."
REPL_JOB=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .id" 2>/dev/null)
if [ -n "$REPL_JOB" ]; then
    test_result "Replication job exists (${REPL_JOB})" 0
else
    test_result "Replication job exists" 1
fi

# Test 6: Replication target is correct
echo "6. Replication target test..."
REPL_TARGET=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .target" 2>/dev/null)
if [ "$REPL_TARGET" = "$HANODE" ]; then
    test_result "Replication target is ${HANODE}" 0
else
    test_result "Replication target is ${HANODE} (got: ${REPL_TARGET})" 1
fi

# Test 7: Replication schedule is correct
echo "7. Replication schedule test..."
REPL_SCHED=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .schedule" 2>/dev/null)
if [ "$REPL_SCHED" = "$REPLICATION_SCHEDULE" ]; then
    test_result "Replication schedule is ${REPLICATION_SCHEDULE}" 0
else
    test_result "Replication schedule is ${REPLICATION_SCHEDULE} (got: ${REPL_SCHED})" 1
fi

# Test 8: Replication status is OK
echo "8. Replication status test..."
REPL_STATE=$(ssh "root@${NODE}.${MGMT}.internal" "pvesr status" 2>/dev/null | grep "^${VMID}-" | awk '{print $NF}')
if [ "$REPL_STATE" = "OK" ]; then
    test_result "Replication state is OK" 0
else
    test_result "Replication state is OK (got: ${REPL_STATE})" 1
fi

# Test 9: Disks replicated to HA node
echo "9. Replicated disks test..."
HANODE_FQDN="${HANODE}.${MGMT}.internal"
DISK_COUNT=$(ssh "root@${HANODE_FQDN}" "zfs list | grep 'vm-${VMID}-disk' | wc -l" 2>/dev/null)
if [ "$DISK_COUNT" -ge 2 ]; then
    test_result "VM disks replicated to ${HANODE} (${DISK_COUNT} disks found)" 0
else
    test_result "VM disks replicated to ${HANODE} (expected >=2, got: ${DISK_COUNT})" 1
fi

# Test 10: HA node is reachable
echo "10. HA node reachability test..."
if ssh "root@${HANODE_FQDN}" "hostname" >/dev/null 2>&1; then
    test_result "HA node ${HANODE} is reachable" 0
else
    test_result "HA node ${HANODE} is reachable" 1
fi

# Test 11: Storage exists on HA node
echo "11. HA node storage test..."
if ssh "root@${HANODE_FQDN}" "pvesm status --storage ${STORAGE}" >/dev/null 2>&1; then
    test_result "Storage ${STORAGE} exists on ${HANODE}" 0
else
    test_result "Storage ${STORAGE} exists on ${HANODE}" 1
fi

# Get VM IP and run basic connectivity tests
echo ""
echo "Running basic VM connectivity tests..."
echo ""

# Get VM IP address
VMIP=""
echo "Getting VM IP address..."
for i in {1..3}; do
    VMIP=$(ssh "root@${NODE}.${MGMT}.internal" "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null | \
        jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | head -1)
    if [ -n "$VMIP" ]; then
        echo "  Found via guest agent: ${VMIP}"
        break
    fi
    sleep 5
done

if [ -z "$VMIP" ]; then
    echo -e "  [\e[33mWARN\e[0m] Could not get VM IP address via guest agent"
    # Try DHCP lease lookup
    MAC=$(ssh "root@${NODE}.${MGMT}.internal" "qm config ${VMID}" 2>/dev/null | grep -oP 'net0:.*virtio=\K[^,]+' | tr '[:upper:]' '[:lower:]')
    if [ -n "$MAC" ]; then
        VMIP=$(ssh "root@firewall.${MGMT}.internal" "grep -i '${MAC}' /var/db/dnsmasq.leases" 2>/dev/null | awk '{print $3}')
        if [ -n "$VMIP" ]; then
            echo "  Found via DHCP lease: ${VMIP}"
        fi
    fi
fi

if [ -n "$VMIP" ]; then
    # Test 12: Ping the VM
    echo "12. VM ping test..."
    if ping -c 3 -W 5 "$VMIP" >/dev/null 2>&1; then
        test_result "VM responds to ping (${VMIP})" 0
    else
        test_result "VM responds to ping (${VMIP})" 1
    fi

    # Test 13: SSH access
    echo "13. VM SSH access test..."
    ssh-keygen -R "$VMIP" 2>/dev/null || true
    ssh-keyscan -H "$VMIP" >> ~/.ssh/known_hosts 2>/dev/null
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${VMIP}" "echo 'SSH OK'" >/dev/null 2>&1; then
        test_result "SSH access to VM as tappaas user" 0
    else
        test_result "SSH access to VM as tappaas user" 1
    fi
else
    echo -e "  [\e[33mWARN\e[0m] Skipping VM connectivity tests (no IP address)"
    test_result "VM connectivity tests (skipped - no IP)" 1
fi

# Summary
echo ""
echo "=============================================="
echo "HA Test Summary for ${VMNAME}"
echo "=============================================="
echo -e "  Passed: \e[32m${PASS}\e[0m"
echo -e "  Failed: \e[31m${FAIL}\e[0m"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "[\e[32mSUCCESS\e[0m] All HA tests passed!"
    exit 0
else
    echo -e "[\e[31mFAILURE\e[0m] Some HA tests failed."
    exit 1
fi
