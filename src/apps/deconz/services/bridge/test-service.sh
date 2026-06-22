#!/usr/bin/env bash
#
# deconz:bridge test-service
#
# Verifies the deCONZ Hue-compat API is reachable and the consumer's pinholes
# (REST + SSDP) exist.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi

info "deconz:bridge test-service for consumer: ${BL}${CONSUMER}${CL}"

TARGET="$(dig +short deconz.srvHome.internal 2>/dev/null | head -1)"
if [[ -z "${TARGET}" ]]; then
    warn "  deconz.srvHome.internal does not resolve — using FQDN directly"
    TARGET="deconz.srvHome.internal"
fi

FAILURES=0

# ── Hue-compat REST reachability (TCP 8080) ──────────────────────────
if nc -zv -w 5 "${TARGET}" 8080 2>/dev/null; then
    info "  TCP 8080 (${TARGET}): ${GN}reachable${CL}"
else
    error "  TCP 8080 (${TARGET}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

# ── Pinhole rules (REST 8080/TCP + SSDP 1900/UDP) ────────────────────
for SPEC in "8080:tcp" "1900:udp"; do
    PORT="${SPEC%%:*}"
    RULE="tappaas-svcdep:${CONSUMER}:bridge:deconz:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${SPEC} (${CONSUMER}→deconz): ${GN}present${CL}"
    else
        error "  Pinhole ${SPEC} (${CONSUMER}→deconz): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

if (( FAILURES == 0 )); then
    info "${GN}deconz:bridge test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}deconz:bridge test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
