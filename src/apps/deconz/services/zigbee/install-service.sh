#!/usr/bin/env bash
#
# deconz:zigbee install-service — no provider-side work.
#
# The 'zigbee' service (deCONZ REST+websocket for Home Assistant) is declarative:
# it exposes its ports via pinhole.json so consumers are granted access by
# auto-pinhole (#173). The consumer's firewall:rules install-service compiles it.
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: install-service.sh <consumer-module-name>"
    exit 1
fi

info "deconz:zigbee install-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole via consumer firewall:rules)."
