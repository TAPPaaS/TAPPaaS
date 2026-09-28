#!/usr/bin/env bash
#
# mymodule:myservice delete-service — template stub (ADR-027 D3, D6)
#
# ── REPLACE THE WARNING BELOW WITH THIS SERVICE'S OWN STEPS ──────────────
# delete-service.sh: take it away again, leaving nothing behind on the provider for this consumer.
# The consumer module's name is $1; its config is /home/tappaas/config/$1.json.
# Delete the warning when you write the steps — while it is here, this service
# does nothing for its consumers.
# ─────────────────────────────────────────────────────────────────────────
#
# Usage: delete-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

warn "delete-service.sh has not been implemented for this service — it is a template stub, so nothing was done for ${1:-the consumer}. Please contact the module's developer."
exit 0
