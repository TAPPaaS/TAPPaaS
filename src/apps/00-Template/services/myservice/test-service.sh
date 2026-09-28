#!/usr/bin/env bash
#
# mymodule:myservice test-service — template stub (ADR-027 D3, D6)
#
# ── REPLACE THE WARNING BELOW WITH THIS SERVICE'S OWN CHECKS ─────────────
# Is this consumer's instance of the service actually working? Exit 0 when it
# is, non-zero when it is not. `module test` and the update gate run it.
# Delete the warning when you write the checks.
# ─────────────────────────────────────────────────────────────────────────
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

warn "test-service.sh has not been implemented for this service — ${1:-the consumer}'s use of it is not tested. Please contact the module's developer."
exit 0
