#!/usr/bin/env bash
# deconz:zigbee delete-service — no-op (see install-service.sh).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: delete-service.sh <consumer-module-name>"
    exit 1
fi
info "deconz:zigbee delete-service for consumer '${CONSUMER}' — no-op."
