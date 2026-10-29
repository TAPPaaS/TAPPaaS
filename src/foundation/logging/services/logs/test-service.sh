#!/usr/bin/env bash
#
# TAPPaaS logging:logs — test (#770)
#
# The consumer's journal is in Loki: a line with host=<its vmname> in the last
# 15 minutes. A syslog sender (the firewall, a node; ADR-039 D9) counts under its
# full hostname too (network.internal): on the update that brings logging's
# relabel, the firewall's own check can run before the logging VM is rebuilt. Asked of Loki's query port from the mothership (mgmt), with the
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
KIND="$(log_shipping_syslog_kind "${CONSUMER}")"
SEL="{host=\"${HOST}\"}"
[[ -n "${KIND}" ]] && SEL="{host=~\"${HOST}|${HOST}[.].+\"}"
WHAT="journal"; [[ -n "${KIND}" ]] && WHAT="syslog"
n="$(log_shipping_curl_admin -fsS --max-time 15 -G "${LOKI}/loki/api/v1/query" \
        --data-urlencode "query=sum(count_over_time(${SEL}[15m]))" 2>/dev/null \
     | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "")"
if [[ -z "${n}" ]]; then
    warn "    Loki did not answer at ${LOKI} — cannot verify ${HOST}'s ${WHAT}"
    exit 0
fi
if [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]; then
    info "    ${GN}✓${CL} ${HOST}'s ${WHAT} is in Loki (${n} lines in 15 min)"
    exit 0
fi
case "${KIND}" in
    opnsense) error "    ✗ no line from host=${HOST} in Loki in 15 min — is OPNsense's remote syslog target (logging:1514) set? (syslog-manager list)" ;;
    node)     error "    ✗ no line from host=${HOST} in Loki in 15 min — is rsyslog running on ${HOST} with /etc/rsyslog.d/99-tappaas-loki.conf?" ;;
    *)        error "    ✗ no line from host=${HOST} in Loki in 15 min — is tappaas-logging.nix on the VM (update-module.sh ${CONSUMER}), alloy running, and the pinhole to :3101 in place?" ;;
esac
exit 1
