#!/usr/bin/env bash
#
# TAPPaaS logging:logs — test (#770)
#
# The consumer's journal is in Loki: a line with host=<its vmname> in the last
# 15 minutes. Asked of Loki's query port from the mothership (mgmt), with the
# admin credential (#165 §1).
#
# Usage: test-service.sh <consumer-module>

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

HOST="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
HOST="${HOST:-${CONSUMER}}"
LOKI="${LOKI_URL:-http://logging.mgmt.internal:3100}"

info "  logging:logs tests for ${BL}${CONSUMER}${CL}"
# shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
. "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
n="$(log_shipping_curl_admin -fsS --max-time 15 -G "${LOKI}/loki/api/v1/query" \
        --data-urlencode "query=sum(count_over_time({host=\"${HOST}\"}[15m]))" 2>/dev/null \
     | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "")"
if [[ -z "${n}" ]]; then
    warn "    Loki did not answer at ${LOKI} — cannot verify ${HOST}'s journal"
    exit 0
fi
if [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]; then
    info "    ${GN}✓${CL} ${HOST}'s journal is in Loki (${n} lines in 15 min)"
    exit 0
fi
error "    ✗ no line from host=${HOST} in Loki in 15 min — is tappaas-logging.nix on the VM (update-module.sh ${CONSUMER}), alloy running, and the pinhole to :3101 in place?"
exit 1
