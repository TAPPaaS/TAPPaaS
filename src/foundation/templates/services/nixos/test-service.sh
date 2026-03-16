#!/usr/bin/env bash
#
# TAPPaaS Templates NixOS Service - Test
#
# Verifies that the NixOS configuration was applied correctly to a module's VM.
# Called by test-module.sh for any module that depends on templates:nixos.
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

info "  ${BOLD}templates:nixos tests for ${BL}${MODULE}${CL}"
info "  (no tests implemented yet)"

exit 0
