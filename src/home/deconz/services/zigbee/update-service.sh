#!/usr/bin/env bash
# deconz:zigbee update-service — no-op (see install-service.sh).

set -euo pipefail
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: update-service.sh <consumer-module-name>"
    exit 1
fi
info "deconz:zigbee update-service for consumer '${CONSUMER}' — no-op."
