#!/usr/bin/env bash
#
# test-install-overrides.sh — discoverable wrapper for the install-time
# `--<field> <value>` override suite (#264).
#
# The actual tests live in src/foundation/tappaas-cicd/test-vm-creation/
# test-variant.sh — co-located with the VM fixtures the install scripts
# read. This wrapper exists so the suite shows up alongside the other
# tabletop tests under scripts/test/, runs in the same sweep, and produces
# a `summary: N pass, M fail` line that matches their convention.
#
# Coverage (43 cases as of this writing):
#   - 5 variant scenarios on a flat-form fixture (Tests 1-5, 20 cases)
#   - 7 Pattern A scenarios that lock in #264 behavior (Tests PA1-PA7, 23 cases)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${SCRIPT_DIR}/../../test-vm-creation/test-variant.sh"

if [[ ! -x "${SUITE}" ]]; then
    echo "── test-install-overrides.sh ──"
    echo "  ✗ suite not found at ${SUITE}"
    echo
    echo "── summary: 0 pass, 1 fail ──"
    exit 1
fi

# Run the suite; tee its output so the operator sees per-test PASS/FAIL.
out=$("${SUITE}" 2>&1) || true
echo "${out}"

# Translate the suite's "Passed: N / Failed: M" footer into the
# scripts/test/ convention so a multi-suite sweep can aggregate.
# Strip ANSI escapes (the suite emits colors) before extracting numbers.
plain=$(echo "${out}" | sed -E 's/\x1b\[[0-9;]*m//g')
pass=$(echo "${plain}" | sed -nE 's/^  Passed: ([0-9]+).*/\1/p' | tail -1)
fail=$(echo "${plain}" | sed -nE 's/^  Failed: ([0-9]+).*/\1/p' | tail -1)
pass="${pass:-0}"
fail="${fail:-0}"
echo
echo "── summary: ${pass} pass, ${fail} fail ──"
exit "${fail}"
