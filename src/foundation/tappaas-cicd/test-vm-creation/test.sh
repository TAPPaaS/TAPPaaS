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

# Reuse install-module.sh's OWN zone gate (validate_zone_active) rather than
# re-deriving the deployable set here — if the two ever disagree, this suite
# would either attempt installs that are guaranteed to abort, or skip cases that
# would in fact have run.
# shellcheck source=../lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# Is this case's target zone deployable on THIS site? A case pinned to a zone
# the site has not activated is NOT a failure — the site simply cannot host it.
# Echoes the zone state on stdout; returns non-zero when the case must be
# skipped. (validate_zone_active prints its own operator guidance, which is
# noise here, so its output is suppressed and we report a one-line reason.)
zone_unavailable_reason() {
    local name="$1"
    local json="${SCRIPT_DIR}/${name}.json"
    local zone state

    [ -f "$json" ] || return 0          # no config → let the install fail loudly
    zone=$(jq -r '.zone0 // empty' "$json" 2>/dev/null)
    [ -n "$zone" ] || return 0          # no zone0 → nothing to pre-check

    if validate_zone_active "$zone" >/dev/null 2>&1; then
        return 0
    fi
    state=$(jq -r --arg z "$zone" '.[$z].state // "not in zones.json"' \
                 "/home/tappaas/config/zones.json" 2>/dev/null)
    echo "zone ${zone} is ${state}"
    return 1
}

# Test cases: name:type:test_script
# Installation is handled by install-module.sh (dependency-aware)
# Optimized test matrix:
# - test-debian: Debian on mgmt zone (tappaas1)
# - test-deb-nonode: Debian with no explicit node (defaults from configuration.json)
# - test-deb-n3noha: Debian on tappaas3, no cluster:ha in dependsOn
# - test-deb-vlannode: Debian on the srvTest VLAN, different node (tappaas3)
# - test-nixos: NixOS on mgmt zone with HA (tappaas1 -> tappaas3)
# - test-nix-vlannode: NixOS on the srvTest VLAN, different node (tappaas2)
# - test-ubuntu-vlan: Ubuntu on the srvTest VLAN (tappaas2)
declare -a ALL_TESTS=(
    "test-debian:debian:test-vm.sh"
    "test-deb-nonode:debian:test-vm.sh"
    "test-deb-n3noha:debian:test-vm.sh"
    "test-deb-vlannode:debian:test-vm.sh"
    "test-nixos:nixos-ha:test-vm.sh"
    "test-nix-vlannode:nixos:test-vm.sh"
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

    # Environment pre-check: a case pinned to a zone this site has not activated
    # cannot run here. Report it as UNAVAILABLE, distinct from a real failure —
    # attempting the install would abort in install-module.sh's zone gate and
    # look identical to a provisioning regression.
    if [ "$SKIP_INSTALL" = false ]; then
        if ! UNAVAIL_REASON=$(zone_unavailable_reason "$TEST_NAME"); then
            INSTALL_STATUS="unavailable"
            TEST_STATUS="unavailable"
            echo -e "${YELLOW}UNAVAILABLE${NC} (${UNAVAIL_REASON})"
            INSTALL_RESULTS+=("$INSTALL_STATUS")
            TEST_RESULTS+=("$TEST_STATUS")
            continue
        fi
    fi

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
TOTAL_SKIP=0

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
        unavailable) INST_FMT="${YELLOW}N/A${NC}" ;;
        *) INST_FMT="${YELLOW}SKIP${NC}" ;;
    esac

    # Format test result
    case $TST in
        pass)
            TST_FMT="${GREEN}PASS${NC}"
            TOTAL_PASS=$((TOTAL_PASS + 1))
            ;;
        fail)
            TST_FMT="${YELLOW}PARTIAL${NC}"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            ;;
        unavailable)
            # NOT a failure: the site cannot host this case (inactive zone).
            TST_FMT="${YELLOW}N/A${NC}"
            TOTAL_SKIP=$((TOTAL_SKIP + 1))
            ;;
        *)
            TST_FMT="${RED}SKIP${NC}"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            ;;
    esac

    printf "%-20s %-10s %-10s " "$NAME" "$TYPE" "$ZONE"
    echo -e "${INST_FMT}      ${TST_FMT}"

    i=$((i + 1))
done

echo ""
echo "=============================================="
echo -e "Total: ${GREEN}${TOTAL_PASS} passed${NC}, ${RED}${TOTAL_FAIL} failed${NC}, ${YELLOW}${TOTAL_SKIP} unavailable${NC}"
if [ "$TOTAL_SKIP" -gt 0 ]; then
    echo ""
    echo "  ${TOTAL_SKIP} case(s) need a zone this site has not activated — coverage GAP,"
    echo "  not a pass. To exercise them: network-manager enable srvTest &&"
    echo "  network-manager reconcile --apply   (srvTest is the designated QA zone)."
fi
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
