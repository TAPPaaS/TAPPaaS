#!/usr/bin/env bash
#
# deconz:hue-bridge test-service
#
# Verifies diyHue's genuine-grade Hue bridge (fronting deCONZ) is reachable and
# the consumer's pinholes (Hue API + SSDP) exist.
#
# NB (2026-07-02 regression): this used to check deCONZ's own port 8080 on
# deconz.srvHome.internal — a leftover from before diyHue existed (the SysAP-
# facing bridge moved to diyHue on 80/443, intra-zone iotCloud). That mismatch
# let a diyHue outage pass this test as green. Check the ACTUAL hue-bridge
# ports/zone, not deCONZ's.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi

info "deconz:hue-bridge test-service for consumer: ${BL}${CONSUMER}${CL}"

TARGET="$(dig +short deconz.iotCloud.internal 2>/dev/null | head -1)"
if [[ -z "${TARGET}" ]]; then
    warn "  deconz.iotCloud.internal does not resolve — using FQDN directly"
    TARGET="deconz.iotCloud.internal"
fi

FAILURES=0

# ── diyHue Hue API reachability (TCP 80 + 443) ────────────────────────
for PORT in 80 443; do
    if nc -zv -w 5 "${TARGET}" "${PORT}" 2>/dev/null; then
        info "  TCP ${PORT} (${TARGET}): ${GN}reachable${CL}"
    else
        error "  TCP ${PORT} (${TARGET}): ${RD}unreachable${CL} — diyHue container down/misconfigured?"
        (( FAILURES++ )) || true
    fi
done

# ── Pinhole rules ────────────────────────────────────────────────────
# This service is consumed INTRA-zone by the SysAP — both sit in iotCloud, so
# rules-manager writes no rule and never did. Asserting three anyway is what
# failed a correctly-wired consumer on every sweep (#689). Ask instead; the
# ports come from services/hue-bridge/pinhole.json through the same predicate,
# so the SSDP rule's '/UDP' suffix no longer has to be remembered here either.
check_service_pinholes "${CONSUMER}" "deconz:hue-bridge" || (( FAILURES++ )) || true

if (( FAILURES == 0 )); then
    info "${GN}deconz:hue-bridge test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}deconz:hue-bridge test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
