#!/usr/bin/env bash
#
# deconz:zigbee test-service
#
# Verifies deCONZ REST+websocket are reachable and the consumer's pinholes exist.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi

info "deconz:zigbee test-service for consumer: ${BL}${CONSUMER}${CL}"

TARGET="$(dig +short deconz.srvHome.internal 2>/dev/null | head -1)"
if [[ -z "${TARGET}" ]]; then
    warn "  deconz.srvHome.internal does not resolve — using FQDN directly"
    TARGET="deconz.srvHome.internal"
fi

FAILURES=0

# ── TCP reachability (REST 8080 + websocket 8443) ────────────────────
for PORT in 8080 8443; do
    if nc -zv -w 5 "${TARGET}" "${PORT}" 2>/dev/null; then
        info "  TCP ${PORT} (${TARGET}): ${GN}reachable${CL}"
    else
        error "  TCP ${PORT} (${TARGET}): ${RD}unreachable${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Pinhole rules ────────────────────────────────────────────────────
for PORT in 8080 8443; do
    RULE="tappaas-svcdep:${CONSUMER}:zigbee:deconz:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→deconz): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→deconz): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

if (( FAILURES == 0 )); then
    info "${GN}deconz:zigbee test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}deconz:zigbee test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
