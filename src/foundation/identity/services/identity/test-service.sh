#!/usr/bin/env bash
#
# TAPPaaS Identity Service - Test
#
# Verifies that the identity service (Authentik) is functioning correctly.
# Called by test-module.sh for any module that depends on identity:identity.
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

info "  ${BOLD}identity:identity tests for ${BL}${MODULE}${CL}"
info "  (no tests implemented yet)"

exit 0
