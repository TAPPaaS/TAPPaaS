#!/usr/bin/env bash
# test-fw-c 'web' service — update hook. No-op (see install-service.sh).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: update-service.sh <consumer-module-name>"
    exit 1
fi
info "test-fw-c:web update-service for consumer '${CONSUMER}' — no-op."
