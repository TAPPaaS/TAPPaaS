#!/usr/bin/env bash
# test-fw-c 'web' service — delete hook. No-op (see install-service.sh).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: delete-service.sh <consumer-module-name>"
    exit 1
fi
info "test-fw-c:web delete-service for consumer '${CONSUMER}' — no-op."
