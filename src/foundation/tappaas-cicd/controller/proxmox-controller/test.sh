#!/usr/bin/env bash
# Runs this component's co-located unit tests (test-*.sh). Exit non-zero on any fail.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../../lib/component-install-lib.sh"
run_component_test_scripts "${here}"
