#!/usr/bin/env bash
#
# test-fw-c 'web' service — install hook.
#
# The 'web' service is purely declarative: it exposes port 9091 via
# pinhole.json so cross-zone consumers can be granted access by auto-pinhole
# (#173). There's nothing to do per-consumer on the provider side; the work
# happens in the consumer's network:rules invocation. This script just logs
# and exits 0.
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: install-service.sh <consumer-module-name>"
    exit 1
fi

info "test-fw-c:web install-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole handled by consumer's network:rules)."
