#!/usr/bin/env bash
# TAPPaaS VM Creation Test Suite
#
# Runs all VM creation test cases and reports results
# Usage: ./test.sh [test-name] [--skip-install] [--skip-test] [--cleanup]
#
# Arguments:
#   test-name       Optional: Run only the specified test (e.g., test-nixos-ha)
#
# Options:
#   --skip-install  Skip VM installation, only run tests on existing VMs
#   --skip-test     Skip tests, only install VMs
#   --cleanup       Destroy all test VMs after testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR=/home/tappaas/logs
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
SKIP_INSTALL=false
SKIP_TEST=false
CLEANUP=false
SINGLE_TEST=""
for arg in "$@"; do
    case $arg in
        --skip-install) SKIP_INSTALL=true ;;
        --skip-test) SKIP_TEST=true ;;
        --cleanup) CLEANUP=true ;;
        -*) echo "Unknown option: $arg"; exit 1 ;;
        *) SINGLE_TEST="$arg" ;;
    esac
done

# Test cases: name, type, install_script, test_script
# Optimized test matrix:
# - test-debian: Debian on mgmt zone (tappaas1)
# - test-debian-vlan-node: Debian on srv VLAN on different node (tappaas3)
# - test-nixos: NixOS on mgmt zone with HA (tappaas1 -> tappaas2)
# - test-nixos-vlan-node: NixOS on srv VLAN on different node (tappaas2)
# - test-ubuntu-vlan: Ubuntu on srv VLAN (tappaas2) - unchanged per request
declare -a ALL_TESTS=(
    "test-debian:debian:install-debian.sh:test-vm.sh"
    "test-debian-vlan-node:debian:install-debian.sh:test-vm.sh"
    "test-nixos:nixos-ha:install-nixos.sh:test-vm.sh"
    "test-nixos-vlan-node:nixos:install-nixos.sh:test-vm.sh"
    "test-ubuntu-vlan:ubuntu:install-debian.sh:test-vm.sh"
)

# Filter tests if single test specified
declare -a TESTS
if [ -n "$SINGLE_TEST" ]; then
    FOUND=false
    for test_entry in "${ALL_TESTS[@]}"; do
        IFS=':' read -r TEST_NAME _ _ _ <<< "$test_entry"
        if [ "$TEST_NAME" = "$SINGLE_TEST" ]; then
            TESTS=("$test_entry")
            FOUND=true
            break
        fi
    done
    if [ "$FOUND" = false ]; then
        echo "Error: Test '$SINGLE_TEST' not found."
        echo ""
        echo "Available tests:"
        for test_entry in "${ALL_TESTS[@]}"; do
            IFS=':' read -r TEST_NAME _ _ _ <<< "$test_entry"
            echo "  - $TEST_NAME"
        done
        exit 1
    fi
else
    TESTS=("${ALL_TESTS[@]}")
fi

# Results arrays
declare -a INSTALL_RESULTS
declare -a TEST_RESULTS

# Colors
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
NC='\e[0m' # No Color

echo "=============================================="
echo "TAPPaaS VM Creation Test Suite"
echo "Started: $(date)"
echo "=============================================="
echo ""

if [ -n "$SINGLE_TEST" ]; then
    echo "Running single test: $SINGLE_TEST"
else
    echo "Running all tests (${#TESTS[@]} total)"
fi

if [ "$SKIP_INSTALL" = true ]; then
    echo "Mode: Test only (--skip-install)"
elif [ "$SKIP_TEST" = true ]; then
    echo "Mode: Install only (--skip-test)"
else
    echo "Mode: Install and Test"
fi
echo "Logs: ${LOG_DIR}/"
echo ""

# Run each test case
for test_entry in "${TESTS[@]}"; do
    IFS=':' read -r TEST_NAME TEST_TYPE INSTALL_SCRIPT TEST_SCRIPT <<< "$test_entry"

    echo -n "[$TEST_NAME] "

    INSTALL_LOG="${LOG_DIR}/${TIMESTAMP}_${TEST_NAME}_install.log"
    TEST_LOG="${LOG_DIR}/${TIMESTAMP}_${TEST_NAME}_test.log"

    INSTALL_STATUS="skipped"
    TEST_STATUS="pending"

    # Install phase
    if [ "$SKIP_INSTALL" = false ]; then
        echo -n "Installing... "
        if ./${INSTALL_SCRIPT} "$TEST_NAME" > "$INSTALL_LOG" 2>&1; then
            INSTALL_STATUS="pass"
            echo -n "OK. "
        else
            INSTALL_STATUS="fail"
            echo -n "FAILED. "
        fi
    else
        echo -n "Skipped install. "
    fi

    # Test phase (only if install succeeded or was skipped, and test not skipped)
    if [ "$INSTALL_STATUS" != "fail" ] && [ "$SKIP_TEST" = false ]; then
        echo -n "Testing... "

        # Wait a bit for VM to be fully ready if we just installed
        if [ "$SKIP_INSTALL" = false ]; then
            sleep 30
        fi

        if ./${TEST_SCRIPT} "$TEST_NAME" > "$TEST_LOG" 2>&1; then
            TEST_STATUS="pass"
            echo -e "${GREEN}PASS${NC}"
        else
            TEST_STATUS="fail"
            # Extract pass/fail counts from log
            PASS_COUNT=$(grep -oP 'Passed: \e\[32m\K\d+' "$TEST_LOG" 2>/dev/null || echo "?")
            FAIL_COUNT=$(grep -oP 'Failed: \e\[31m\K\d+' "$TEST_LOG" 2>/dev/null || echo "?")
            echo -e "${YELLOW}PARTIAL${NC} (${PASS_COUNT}/${FAIL_COUNT})"
        fi
    elif [ "$SKIP_TEST" = true ]; then
        TEST_STATUS="skipped"
        echo -e "${YELLOW}SKIPPED${NC} (--skip-test)"
    else
        TEST_STATUS="skipped"
        echo -e "${RED}SKIPPED${NC} (install failed)"
    fi

    INSTALL_RESULTS+=("$INSTALL_STATUS")
    TEST_RESULTS+=("$TEST_STATUS")
done

echo ""
echo "=============================================="
echo "Test Results Summary"
echo "=============================================="
echo ""
printf "%-20s %-10s %-10s %-10s %-10s\n" "Test" "Type" "Zone" "Install" "Test"
printf "%-20s %-10s %-10s %-10s %-10s\n" "----" "----" "----" "-------" "----"

# Summary with details
i=0
TOTAL_PASS=0
TOTAL_FAIL=0

test_details=(
    "test-debian:debian:mgmt"
    "test-debian-vlan-node:debian:srv"
    "test-nixos:nixos-ha:mgmt"
    "test-nixos-vlan-node:nixos:srv"
    "test-ubuntu-vlan:ubuntu:srv"
)

for detail in "${test_details[@]}"; do
    IFS=':' read -r NAME TYPE ZONE <<< "$detail"

    INST="${INSTALL_RESULTS[$i]}"
    TST="${TEST_RESULTS[$i]}"

    # Format install result
    case $INST in
        pass) INST_FMT="${GREEN}PASS${NC}" ;;
        fail) INST_FMT="${RED}FAIL${NC}" ;;
        *) INST_FMT="${YELLOW}SKIP${NC}" ;;
    esac

    # Format test result
    case $TST in
        pass)
            TST_FMT="${GREEN}PASS${NC}"
            ((TOTAL_PASS++))
            ;;
        fail)
            TST_FMT="${YELLOW}PARTIAL${NC}"
            ((TOTAL_FAIL++))
            ;;
        *)
            TST_FMT="${RED}SKIP${NC}"
            ((TOTAL_FAIL++))
            ;;
    esac

    printf "%-20s %-10s %-10s " "$NAME" "$TYPE" "$ZONE"
    echo -e "${INST_FMT}      ${TST_FMT}"

    ((i++))
done

echo ""
echo "=============================================="
echo -e "Total: ${GREEN}${TOTAL_PASS} passed${NC}, ${RED}${TOTAL_FAIL} failed${NC}"
echo "Logs saved to: ${LOG_DIR}/"
echo "=============================================="

# Cleanup if requested
if [ "$CLEANUP" = true ]; then
    echo ""
    echo "Cleaning up test VMs..."

    # tappaas1 VMs (including HA VMs)
    # 901: test-debian, 903: test-nixos (with HA)
    for vmid in 901 903; do
        echo "  Removing VM $vmid from tappaas1..."
        # Remove HA configuration first
        ssh root@tappaas1.mgmt.internal "ha-manager remove vm:$vmid 2>/dev/null" || true
        # Remove replication jobs
        ssh root@tappaas1.mgmt.internal "pvesr delete $vmid-0 --force 1 2>/dev/null" || true
        # Stop and destroy VM
        ssh root@tappaas1.mgmt.internal "qm stop $vmid 2>/dev/null; qm destroy $vmid --purge 2>/dev/null" || true
    done

    # tappaas2 VMs
    # 904: test-nixos-vlan-node, 905: test-ubuntu-vlan
    for vmid in 904 905; do
        echo "  Removing VM $vmid from tappaas2..."
        ssh root@tappaas2.mgmt.internal "qm stop $vmid 2>/dev/null; qm destroy $vmid --purge 2>/dev/null" || true
    done

    # tappaas3 VMs
    # 902: test-debian-vlan-node
    for vmid in 902; do
        echo "  Removing VM $vmid from tappaas3..."
        ssh root@tappaas3.mgmt.internal "qm stop $vmid 2>/dev/null; qm destroy $vmid --purge 2>/dev/null" || true
    done

    # Clean up HA rules
    echo "  Cleaning up HA rules..."
    for rule in ha-test-nixos; do
        ssh root@tappaas1.mgmt.internal "ha-manager rules remove $rule 2>/dev/null" || true
    done

    echo "Cleanup complete."
fi

# Exit with appropriate code
if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
