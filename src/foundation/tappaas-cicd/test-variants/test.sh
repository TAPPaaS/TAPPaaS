#!/usr/bin/env bash
#
# test-variants/test.sh — variant test-suite orchestrator (ADR-005 / #316).
#
# Runs every test-variant-*.sh in this directory and aggregates pass/fail by
# exit code. Unit tests run unconditionally and are fast (offline). Integration
# tests (added in later sprints) self-gate on TAPPAAS_TEST_DEEP and create/destroy
# real VMs in the reserved 8900-8999 VMID range.
#
# Usage:
#   ./test.sh                     # run all variant tests
#   TAPPAAS_TEST_DEEP=1 ./test.sh # also run integration/cluster tests
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

SUITES_PASS=0
SUITES_FAIL=0
FAILED_SUITES=()

echo "════════════════════════════════════════════"
echo "  TAPPaaS Variant Test Suite (ADR-005)"
echo "  Deep mode: ${TAPPAAS_TEST_DEEP:-0}"
echo "════════════════════════════════════════════"

shopt -s nullglob
for t in "${SCRIPT_DIR}"/test-variant-*.sh; do
    [[ -x "$t" ]] || chmod +x "$t"
    name="$(basename "$t")"
    echo ""
    echo "── ${name} ─────────────────────────────────"
    if "$t"; then
        echo "  ${name}: PASS"
        SUITES_PASS=$((SUITES_PASS + 1))
    else
        echo "  ${name}: FAIL"
        SUITES_FAIL=$((SUITES_FAIL + 1))
        FAILED_SUITES+=("${name}")
    fi
done
shopt -u nullglob

echo ""
echo "════════════════════════════════════════════"
echo "  Variant suites: ${SUITES_PASS} passed, ${SUITES_FAIL} failed"
[[ "${SUITES_FAIL}" -gt 0 ]] && echo "  Failed: ${FAILED_SUITES[*]}"
echo "════════════════════════════════════════════"

[[ "${SUITES_FAIL}" -eq 0 ]]
