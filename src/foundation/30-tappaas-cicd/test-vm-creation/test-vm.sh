#!/usr/bin/env bash
# TAPPaaS VM Test Script
#
# Tests that a VM is working correctly after installation
# Includes HA tests when HANode is specified in the VM config
# Usage: ./test.sh <vmname>
# Example: ./test.sh test-debian

. /home/tappaas/bin/common-install-routines.sh

if [ -z "$1" ]; then
    echo "Usage: ./test.sh <vmname>"
    echo "Example: ./test.sh test-debian"
    exit 1
fi

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' 'NONE')"
REPLICATION_SCHEDULE="$(get_config_value 'replicationSchedule' '*/15')"
STORAGE="$(get_config_value 'storage' 'tanka1')"
MGMT="mgmt"

echo "=============================================="
echo "Testing VM: ${VMNAME} (VMID: ${VMID})"
echo "Node: ${NODE}, Zone: ${ZONE0NAME}"
if [ -n "$HANODE" ] && [ "$HANODE" != "NONE" ]; then
    echo "HA Node: ${HANODE}"
fi
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

# Get VM IP address - try guest agent first, then fall back to DHCP lease
echo "Getting VM IP address..."
VMIP=""

# Method 1: Try guest agent
echo "  Trying guest agent..."
for i in {1..3}; do
    VMIP=$(ssh "root@${NODE}.${MGMT}.internal" "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null | \
        jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | head -1)
    if [ -n "$VMIP" ]; then
        echo "  Found via guest agent: ${VMIP}"
        break
    fi
    sleep 5
done

# Method 2: Fall back to DHCP lease lookup by MAC address
if [ -z "$VMIP" ]; then
    echo "  Guest agent not available, trying DHCP lease lookup..."
    # Get MAC address from VM config (format: net0: virtio=XX:XX:XX:XX:XX:XX,bridge=...)
    MAC=$(ssh "root@${NODE}.${MGMT}.internal" "qm config ${VMID}" 2>/dev/null | grep -oP 'net0:.*virtio=\K[^,]+' | tr '[:upper:]' '[:lower:]')
    if [ -n "$MAC" ]; then
        echo "  VM MAC address: ${MAC}"
        # Look up IP in DHCP leases
        VMIP=$(ssh "root@firewall.${MGMT}.internal" "grep -i '${MAC}' /var/db/dnsmasq.leases" 2>/dev/null | awk '{print $3}')
        if [ -n "$VMIP" ]; then
            echo "  Found via DHCP lease: ${VMIP}"
        fi
    fi
fi

if [ -z "$VMIP" ]; then
    echo -e "[\e[31mFAIL\e[0m] Could not get VM IP address"
    exit 1
fi
echo "VM IP: ${VMIP}"
echo ""

# Determine expected DNS name based on zone
if [ "$ZONE0NAME" = "mgmt" ]; then
    DNS_NAME="${VMNAME}.${MGMT}.internal"
else
    DNS_NAME="${VMNAME}.${ZONE0NAME}.internal"
fi

echo "Running tests..."
echo ""

# Test 1: Ping the VM by IP
echo "1. Ping test (by IP)..."
ping -c 3 -W 5 "$VMIP" >/dev/null 2>&1
test_result "Ping VM by IP ($VMIP)" $?

# Test 2: DNS resolution
echo "2. DNS resolution test..."
RESOLVED_IP=$(getent hosts "$DNS_NAME" 2>/dev/null | awk '{print $1}' | head -1)
if [ "$RESOLVED_IP" = "$VMIP" ]; then
    test_result "DNS resolves $DNS_NAME to $VMIP" 0
else
    echo "  Expected: $VMIP, Got: $RESOLVED_IP"
    test_result "DNS resolves $DNS_NAME to $VMIP" 1
fi

# Test 3: Ping by DNS name
echo "3. Ping test (by DNS name)..."
ping -c 3 -W 5 "$DNS_NAME" >/dev/null 2>&1
test_result "Ping VM by DNS name ($DNS_NAME)" $?

# Test 4: SSH access
echo "4. SSH access test..."
# Update known_hosts
ssh-keygen -R "$VMIP" 2>/dev/null || true
ssh-keyscan -H "$VMIP" >> ~/.ssh/known_hosts 2>/dev/null

# Try SSH - different users for Debian vs NixOS
if ssh -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${VMIP}" "echo 'SSH OK'" >/dev/null 2>&1; then
    test_result "SSH access as tappaas user" 0
    SSH_USER="tappaas"
elif ssh -o ConnectTimeout=10 -o BatchMode=yes "debian@${VMIP}" "echo 'SSH OK'" >/dev/null 2>&1; then
    test_result "SSH access as debian user" 0
    SSH_USER="debian"
else
    test_result "SSH access (tappaas or debian user)" 1
    SSH_USER=""
fi

# Test 5: Hostname verification
echo "5. Hostname verification..."
if [ -n "$SSH_USER" ]; then
    ACTUAL_HOSTNAME=$(ssh -o ConnectTimeout=10 "${SSH_USER}@${VMIP}" "hostname" 2>/dev/null)
    if [ "$ACTUAL_HOSTNAME" = "$VMNAME" ]; then
        test_result "Hostname is $VMNAME" 0
    else
        echo "  Expected: $VMNAME, Got: $ACTUAL_HOSTNAME"
        test_result "Hostname is $VMNAME" 1
    fi
else
    test_result "Hostname verification (skipped - no SSH)" 1
fi

# Test 6: Internet access from VM
echo "6. Internet access test..."
if [ -n "$SSH_USER" ]; then
    if ssh -o ConnectTimeout=10 "${SSH_USER}@${VMIP}" "ping -c 2 -W 5 1.1.1.1" >/dev/null 2>&1; then
        test_result "VM can ping 1.1.1.1 (internet)" 0
    else
        test_result "VM can ping 1.1.1.1 (internet)" 1
    fi
else
    test_result "Internet access (skipped - no SSH)" 1
fi

# Test 7: DNS from VM
echo "7. DNS resolution from VM..."
if [ -n "$SSH_USER" ]; then
    if ssh -o ConnectTimeout=10 "${SSH_USER}@${VMIP}" "ping -c 2 -W 5 google.com" >/dev/null 2>&1; then
        test_result "VM can resolve and ping google.com" 0
    else
        test_result "VM can resolve and ping google.com" 1
    fi
else
    test_result "DNS from VM (skipped - no SSH)" 1
fi

# Test 8: Disk size verification
echo "8. Disk size verification..."
EXPECTED_DISK_SIZE="$(get_config_value 'diskSize' '8G')"
# Extract numeric value and unit (e.g., "24G" -> 24)
EXPECTED_SIZE_NUM="${EXPECTED_DISK_SIZE%[GMTK]}"
if [ -n "$SSH_USER" ]; then
    # Get actual root filesystem size in GB (rounded)
    ACTUAL_SIZE=$(ssh -o ConnectTimeout=10 "${SSH_USER}@${VMIP}" "df -BG / | tail -1 | awk '{print \$2}'" 2>/dev/null | tr -d 'G')
    if [ -n "$ACTUAL_SIZE" ]; then
        # Allow 10% tolerance for filesystem overhead
        MIN_EXPECTED=$((EXPECTED_SIZE_NUM * 85 / 100))
        if [ "$ACTUAL_SIZE" -ge "$MIN_EXPECTED" ]; then
            test_result "Disk size is ~${EXPECTED_DISK_SIZE} (actual: ${ACTUAL_SIZE}G)" 0
        else
            echo "  Expected: >= ${MIN_EXPECTED}G (85% of ${EXPECTED_DISK_SIZE}), Got: ${ACTUAL_SIZE}G"
            test_result "Disk size is ~${EXPECTED_DISK_SIZE} (actual: ${ACTUAL_SIZE}G)" 1
        fi
    else
        test_result "Disk size verification (could not get size)" 1
    fi
else
    test_result "Disk size verification (skipped - no SSH)" 1
fi

# HA Tests (only if HANode is specified)
if [ -n "$HANODE" ] && [ "$HANODE" != "NONE" ]; then
    echo ""
    echo "Running HA configuration tests..."
    echo ""
    HANODE_FQDN="${HANODE}.${MGMT}.internal"

    # HA Test 1: VM is in HA resources
    echo "9. HA resource test..."
    HA_RESOURCE=$(ssh "root@${NODE}.${MGMT}.internal" "ha-manager config" 2>/dev/null | grep "^vm:${VMID}")
    if [ -n "$HA_RESOURCE" ]; then
        test_result "VM ${VMID} is registered in HA resources" 0
    else
        test_result "VM ${VMID} is registered in HA resources" 1
    fi

    # HA Test 2: HA rule exists
    echo "10. HA rule test..."
    HA_RULE_NAME="ha-${VMNAME}"
    HA_RULE=$(ssh "root@${NODE}.${MGMT}.internal" "ha-manager rules list" 2>/dev/null | grep "${HA_RULE_NAME}")
    if [ -n "$HA_RULE" ]; then
        test_result "HA rule '${HA_RULE_NAME}' exists" 0
    else
        test_result "HA rule '${HA_RULE_NAME}' exists" 1
    fi

    # HA Test 3: Node-affinity rule configuration
    echo "11. Node-affinity rule configuration test..."
    RULE_CONFIG=$(ssh "root@${NODE}.${MGMT}.internal" "cat /etc/pve/ha/rules.cfg" 2>/dev/null | grep -A 2 "${HA_RULE_NAME}")
    if echo "$RULE_CONFIG" | grep -q "nodes ${NODE}:2,${HANODE}:1"; then
        test_result "Node-affinity priorities correct (${NODE}:2, ${HANODE}:1)" 0
    else
        test_result "Node-affinity priorities correct (${NODE}:2, ${HANODE}:1)" 1
    fi

    # HA Test 4: Replication job exists
    echo "12. Replication job test..."
    REPL_JOB=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .id" 2>/dev/null)
    if [ -n "$REPL_JOB" ]; then
        test_result "Replication job exists (${REPL_JOB})" 0
    else
        test_result "Replication job exists" 1
    fi

    # HA Test 5: Replication target is correct
    echo "13. Replication target test..."
    REPL_TARGET=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .target" 2>/dev/null)
    if [ "$REPL_TARGET" = "$HANODE" ]; then
        test_result "Replication target is ${HANODE}" 0
    else
        test_result "Replication target is ${HANODE} (got: ${REPL_TARGET})" 1
    fi

    # HA Test 6: Replication schedule is correct
    echo "14. Replication schedule test..."
    REPL_SCHED=$(ssh "root@${NODE}.${MGMT}.internal" "pvesh get /cluster/replication --output-format=json" 2>/dev/null | jq -r ".[] | select(.guest == ${VMID}) | .schedule" 2>/dev/null)
    if [ "$REPL_SCHED" = "$REPLICATION_SCHEDULE" ]; then
        test_result "Replication schedule is ${REPLICATION_SCHEDULE}" 0
    else
        test_result "Replication schedule is ${REPLICATION_SCHEDULE} (got: ${REPL_SCHED})" 1
    fi

    # HA Test 7: Replication status is OK
    echo "15. Replication status test..."
    REPL_STATE=$(ssh "root@${NODE}.${MGMT}.internal" "pvesr status" 2>/dev/null | grep "^${VMID}-" | awk '{print $NF}')
    if [ "$REPL_STATE" = "OK" ]; then
        test_result "Replication state is OK" 0
    else
        test_result "Replication state is OK (got: ${REPL_STATE})" 1
    fi

    # HA Test 8: Disks replicated to HA node
    echo "16. Replicated disks test..."
    DISK_COUNT=$(ssh "root@${HANODE_FQDN}" "zfs list | grep 'vm-${VMID}-disk' | wc -l" 2>/dev/null)
    if [ "$DISK_COUNT" -ge 2 ]; then
        test_result "VM disks replicated to ${HANODE} (${DISK_COUNT} disks found)" 0
    else
        test_result "VM disks replicated to ${HANODE} (expected >=2, got: ${DISK_COUNT})" 1
    fi

    # HA Test 9: HA node is reachable
    echo "17. HA node reachability test..."
    if ssh "root@${HANODE_FQDN}" "hostname" >/dev/null 2>&1; then
        test_result "HA node ${HANODE} is reachable" 0
    else
        test_result "HA node ${HANODE} is reachable" 1
    fi

    # HA Test 10: Storage exists on HA node
    echo "18. HA node storage test..."
    if ssh "root@${HANODE_FQDN}" "pvesm status --storage ${STORAGE}" >/dev/null 2>&1; then
        test_result "Storage ${STORAGE} exists on ${HANODE}" 0
    else
        test_result "Storage ${STORAGE} exists on ${HANODE}" 1
    fi
fi

# Summary
echo ""
echo "=============================================="
echo "Test Summary for ${VMNAME}"
echo "=============================================="
echo -e "  Passed: \e[32m${PASS}\e[0m"
echo -e "  Failed: \e[31m${FAIL}\e[0m"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "[\e[32mSUCCESS\e[0m] All tests passed!"
    exit 0
else
    echo -e "[\e[31mFAILURE\e[0m] Some tests failed."
    exit 1
fi
