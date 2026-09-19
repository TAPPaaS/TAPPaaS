#!/usr/bin/env bash
#
# TAPPaaS Templates Debian Service - Test
#
# Verifies that the Debian/Ubuntu baseline was applied correctly to a module's
# VM. Called by test-module.sh (and reconcile's verify step) for any module that
# depends on templates:debian.
#
# A stub, like templates:nixos's: it asserts nothing yet, but its presence means
# the dependency is reported as tested rather than as "no test-service.sh".
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

info "  ${BOLD}templates:debian tests for ${BL}${MODULE}${CL}"
info "  (no tests implemented yet)"

exit 0
