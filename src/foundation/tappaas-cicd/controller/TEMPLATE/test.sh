#!/usr/bin/env bash
# TEMPLATE/test.sh — copy this directory to scaffold a new controller component.
# The parent dispatcher SKIPS TEMPLATE/, so this stub never runs in place.
#
# FAST/DEEP convention (see ../../README.md "Testing: fast vs deep slices"):
#   default = FAST + non-disruptive (schema/CLI/validation + mocked logic);
#   gate disruptive/live tests behind: if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]];
#   and add a one-line smoke for this component to cicd test.sh "Test 11".
set -euo pipefail
echo "[TEMPLATE] test: self-contained tests; exit non-zero on failure"
