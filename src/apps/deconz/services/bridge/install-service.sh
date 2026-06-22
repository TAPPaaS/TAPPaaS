#!/usr/bin/env bash
#
# deconz:bridge install-service — no provider-side work.
#
# The 'bridge' service is the native Hue-compatible API (replaces HA emulated_hue).
# Declarative: it exposes its ports via pinhole.json so cross-zone consumers
# (e.g. SysAP in iotCloud) are granted access by auto-pinhole (#173). The
# consumer's firewall:rules install-service compiles it. NB cross-zone SSDP
# discovery additionally requires the firewall:discovery relay (UDP 1900).
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: install-service.sh <consumer-module-name>"
    exit 1
fi

info "deconz:bridge install-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole via consumer firewall:rules; SSDP relay via firewall:discovery)."
