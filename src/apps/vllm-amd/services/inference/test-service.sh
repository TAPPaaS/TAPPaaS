#!/usr/bin/env bash
#
# vllm-amd:inference test-service
#
# Verifies that the vLLM OpenAI-compatible API is up on its declared port and
# that the consumer's auto-pinhole rule is present in OPNsense.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/vllm-amd.json"

info "vllm-amd:inference test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 is read from the DEPLOYED config, not from the module source: the source
# declares zone0 as null — the zone is assigned at install time — so reading it
# there would build "vllm-amd.null.internal" and never resolve.
ZONE0="$(read_module_config vllm-amd 2>/dev/null | jq -r '.zone0 // "srvWork"')"
VLLM_FQDN="vllm-amd.${ZONE0}.internal"

VLLM_IP=$(dig +short "${VLLM_FQDN}" 2>/dev/null | head -1)
if [[ -z "${VLLM_IP}" ]]; then
    warn "  ${VLLM_FQDN} does not resolve — falling back to the name"
fi

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────
#
# services/inference/pinhole.json declares exactly one port, TCP 8000, so the
# probe and the pinhole loop below use the same single port. Do not widen either
# without widening the pinhole first — a rule that is never declared can never
# be found.
#
# What this probe does and does not prove: it runs from the management zone,
# which reaches every zone by design, so a green line here says the service is
# LISTENING — it says nothing about whether the consumer can reach it. The
# consumer's path is what the pinhole check below covers.

TARGET="${VLLM_IP:-${VLLM_FQDN}}"
if nc -zv -w 5 "${TARGET}" 8000 2>/dev/null; then
    info "  TCP 8000 (${TARGET}): ${GN}listening${CL}"
else
    error "  TCP 8000 (${TARGET}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

# ── Pinhole rules ────────────────────────────────────────────────────
#
# Both relationship lists synthesise an auto-pinhole: rules-manager walks
# dependsOn AND integratesWith (#632), so a consumer that declares this service
# either way carries a rule named below. module-manager's own dependency test
# step walks dependsOn only, so a consumer of the integratesWith kind never
# reaches this script — its rule exists and goes unverified.

for PORT in 8000; do
    RULE="tappaas-svcdep:${CONSUMER}:inference:vllm-amd:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→vllm-amd): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→vllm-amd): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}vllm-amd:inference test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}vllm-amd:inference test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
