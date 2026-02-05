#!/usr/bin/env bash
# TAPPaaS VM Creation Test Suite
#
# Runs all 6 VM creation test cases and reports results
# Usage: ./test.sh [--skip-install] [--cleanup]
#
# Options:
#   --skip-install  Skip VM installation, only run tests on existing VMs
#   --cleanup       Destroy all test VMs after testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR=/home/tappaas/logs
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
SKIP_INSTALL=false
CLEANUP=false
for arg in "$@"; do
    case $arg in
        --skip-install) SKIP_INSTALL=true ;;
        --cleanup) CLEANUP=true ;;
    esac
done

# Test cases: name, type, install_script
declare -a TESTS=(
    "test-debian:debian:install-debian.sh"
    "test-debian-vlan:debian:install-debian.sh"
    "test-debian-node:debian:install-debian.sh"
    "test-nixos:nixos:install-nixos.sh"
    "test-nixos-vlan:nixos:install-nixos.sh"
    "test-nixos-node:nixos:install-nixos.sh"
)

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

if [ "$SKIP_INSTALL" = true ]; then
    echo "Mode: Test only (--skip-install)"
else
    echo "Mode: Install and Test"
fi
echo "Logs: ${LOG_DIR}/"
echo ""

# Run each test case
for test_entry in "${TESTS[@]}"; do
    IFS=':' read -r TEST_NAME TEST_TYPE INSTALL_SCRIPT <<< "$test_entry"

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

    # Test phase (only if install succeeded or was skipped)
    if [ "$INSTALL_STATUS" != "fail" ]; then
        echo -n "Testing... "

        # Wait a bit for VM to be fully ready if we just installed
        if [ "$SKIP_INSTALL" = false ]; then
            sleep 30
        fi

        if ./test-vm.sh "$TEST_NAME" > "$TEST_LOG" 2>&1; then
            TEST_STATUS="pass"
            echo -e "${GREEN}PASS${NC}"
        else
            TEST_STATUS="fail"
            # Extract pass/fail counts from log
            PASS_COUNT=$(grep -oP 'Passed: \e\[32m\K\d+' "$TEST_LOG" 2>/dev/null || echo "?")
            FAIL_COUNT=$(grep -oP 'Failed: \e\[31m\K\d+' "$TEST_LOG" 2>/dev/null || echo "?")
            echo -e "${YELLOW}PARTIAL${NC} (${PASS_COUNT}/${FAIL_COUNT})"
        fi
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
    "test-debian-vlan:debian:srv"
    "test-debian-node:debian:srv"
    "test-nixos:nixos:mgmt"
    "test-nixos-vlan:nixos:srv"
    "test-nixos-node:nixos:srv"
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

    # tappaas1 VMs
    for vmid in 601 602 604 605; do
        ssh root@tappaas1.mgmt.internal "qm stop $vmid 2>/dev/null; qm destroy $vmid --purge 2>/dev/null" || true
    done

    # tappaas2 VMs
    for vmid in 603 606; do
        ssh root@tappaas2.mgmt.internal "qm stop $vmid 2>/dev/null; qm destroy $vmid --purge 2>/dev/null" || true
    done

    echo "Cleanup complete."
fi

# Exit with appropriate code
if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
