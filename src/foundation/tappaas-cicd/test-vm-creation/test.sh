#!/usr/bin/env bash
# TAPPaaS VM Creation Test Suite
#
# Runs all VM creation test cases and reports results
# Usage: ./test.sh [test-name] [--skip-install] [--skip-test] [--skip-delete]
#
# Arguments:
#   test-name       Optional: Run only the specified test (e.g., test-nixos-ha)
#
# Options:
#   --skip-install  Skip VM installation, only run tests on existing VMs
#   --skip-test     Skip tests, only install VMs
#   --skip-delete   Skip VM deletion after testing (by default, test VMs are deleted)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR=/home/tappaas/logs
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
SKIP_INSTALL=false
SKIP_TEST=false
DELETE=true
SINGLE_TEST=""
for arg in "$@"; do
    case $arg in
        --skip-install) SKIP_INSTALL=true ;;
        --skip-test) SKIP_TEST=true ;;
        --skip-delete) DELETE=false ;;
        -*) echo "Unknown option: $arg"; exit 1 ;;
        *) SINGLE_TEST="$arg" ;;
    esac
done

# Test cases: name:type:test_script
# Installation is handled by install-module.sh (dependency-aware)
# Optimized test matrix:
# - test-debian: Debian on mgmt zone (tappaas1)
# - test-debian-vlan-node: Debian on srv VLAN on different node (tappaas3)
# - test-nixos: NixOS on mgmt zone with HA (tappaas1 -> tappaas2)
# - test-nixos-vlan-node: NixOS on srv VLAN on different node (tappaas2)
# - test-ubuntu-vlan: Ubuntu on srv VLAN (tappaas2) - unchanged per request
declare -a ALL_TESTS=(
    "test-debian:debian:test-vm.sh"
    "test-debian-vlan-node:debian:test-vm.sh"
    "test-nixos:nixos-ha:test-vm.sh"
    "test-nixos-vlan-node:nixos:test-vm.sh"
    "test-ubuntu-vlan:ubuntu:test-vm.sh"
)

# Filter tests if single test specified
declare -a TESTS
if [ -n "$SINGLE_TEST" ]; then
    FOUND=false
    for test_entry in "${ALL_TESTS[@]}"; do
        IFS=':' read -r TEST_NAME _ _ <<< "$test_entry"
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
            IFS=':' read -r TEST_NAME _ _ <<< "$test_entry"
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
    IFS=':' read -r TEST_NAME TEST_TYPE TEST_SCRIPT <<< "$test_entry"

    echo -n "[$TEST_NAME] "

    INSTALL_LOG="${LOG_DIR}/${TIMESTAMP}_${TEST_NAME}_install.log"
    TEST_LOG="${LOG_DIR}/${TIMESTAMP}_${TEST_NAME}_test.log"

    INSTALL_STATUS="skipped"
    TEST_STATUS="pending"

    # Install phase
    if [ "$SKIP_INSTALL" = false ]; then
        echo -n "Installing... "
        if /home/tappaas/bin/install-module.sh "$TEST_NAME" > "$INSTALL_LOG" 2>&1; then
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

# Summary with details - iterate over the tests that actually ran
i=0
TOTAL_PASS=0
TOTAL_FAIL=0

for test_entry in "${TESTS[@]}"; do
    IFS=':' read -r NAME TYPE _ <<< "$test_entry"

    # Get zone from JSON config
    JSON_FILE="${SCRIPT_DIR}/${NAME}.json"
    if [ -f "$JSON_FILE" ]; then
        ZONE=$(python3 -c "import json; print(json.load(open('$JSON_FILE')).get('zone0','?'))" 2>/dev/null || echo "?")
    else
        ZONE="?"
    fi

    INST="${INSTALL_RESULTS[$i]:-skipped}"
    TST="${TEST_RESULTS[$i]:-skipped}"

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

# Delete test VMs (default behavior unless --skip-delete)
if [ "$DELETE" = true ]; then
    echo ""
    echo "Deleting test VMs..."

    for test_entry in "${TESTS[@]}"; do
        IFS=':' read -r TEST_NAME _ _ <<< "$test_entry"

        # Check if the module config exists (it might not if install was skipped/failed)
        if [ ! -f "/home/tappaas/config/${TEST_NAME}.json" ]; then
            echo "  Skipping ${TEST_NAME} (no config found)"
            continue
        fi

        DELETE_LOG="${LOG_DIR}/${TIMESTAMP}_${TEST_NAME}_delete.log"
        echo -n "  Deleting ${TEST_NAME}... "
        if /home/tappaas/bin/delete-module.sh "${TEST_NAME}" --force > "${DELETE_LOG}" 2>&1; then
            echo "OK"
        else
            echo "FAILED (see ${DELETE_LOG})"
        fi
    done

    echo "Deletion complete."
fi

# Exit with appropriate code
if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
