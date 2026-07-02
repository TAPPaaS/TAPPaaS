#!/usr/bin/env bash
#
# deconz:hue-bridge test-service
#
# Verifies diyHue's genuine-grade Hue bridge (fronting deCONZ) is reachable and
# the consumer's pinholes (Hue API + SSDP) exist.
#
# NB (2026-07-02 regression): this used to check deCONZ's own port 8080 on
# deconz.srvHome.internal — a leftover from before diyHue existed (ADR-COM-0006/
# 0007 moved the SysAP-facing bridge to diyHue on 80/443, intra-zone iotCloud).
# That mismatch let a diyHue outage pass this test as green. Check the ACTUAL
# hue-bridge ports/zone, not deCONZ's.
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

# ── Pinhole rules (Hue API 80+443/TCP + SSDP 1900/UDP) ────────────────
for SPEC in "80:tcp" "443:tcp" "1900:udp"; do
    PORT="${SPEC%%:*}"
    RULE="tappaas-svcdep:${CONSUMER}:hue-bridge:deconz:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${SPEC} (${CONSUMER}→deconz): ${GN}present${CL}"
    else
        error "  Pinhole ${SPEC} (${CONSUMER}→deconz): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

if (( FAILURES == 0 )); then
    info "${GN}deconz:hue-bridge test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}deconz:hue-bridge test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
