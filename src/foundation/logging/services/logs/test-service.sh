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
info "  logging:logs tests for ${BL}${CONSUMER}${CL}"
# shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
. "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
# Over TLS once logging serves it (#787), the plain port until then.
LOKI="${LOKI_URL:-$(log_shipping_query_url)}"
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
    # Its own performance numbers ride on the same client (ADR-046): said, never
    # failed — a guest gets them after its first OS update with this release.
    if [[ -z "${KIND}" && -f "${METRICS_SHIPPING_LIB:-/home/tappaas/bin/metrics-shipping.sh}" ]]; then
        # shellcheck source=../../../tappaas-cicd/lib/metrics-shipping.sh
        . "${METRICS_SHIPPING_LIB:-/home/tappaas/bin/metrics-shipping.sh}"
        lvl="$(metrics_effective "${CONSUMER}" 2>/dev/null | jq -r '.level // "off"')"
        if metrics_wanted && [[ "${lvl}" != off ]]; then
            m="$(metrics_curl_admin -fsS --max-time 15 -G "$(metrics_query_url)/api/v1/query" \
                    --data-urlencode "query=count(count_over_time(node_load1{host=\"${HOST}\",tappaas_ci_id!=\"\"}[5m]))" 2>/dev/null \
                 | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "")"
            if [[ "${m}" =~ ^[1-9] ]]; then info "    ${GN}✓${CL} ${HOST}'s own numbers are in the metrics store (level ${lvl})"
            else warn "    ${HOST} is at performance level ${lvl}, but none of its own numbers reached the store in 5 min — its next OS update brings the collector"; fi
        fi
    fi
    exit 0
fi
case "${KIND}" in
    opnsense) error "    ✗ no line from host=${HOST} in Loki in 15 min — is OPNsense's remote syslog target (logging:1514) set? (syslog-manager list)" ;;
    node)     error "    ✗ no line from host=${HOST} in Loki in 15 min — is rsyslog running on ${HOST} with /etc/rsyslog.d/99-tappaas-loki.conf?" ;;
    *)        error "    ✗ no line from host=${HOST} in Loki in 15 min — is tappaas-logging.nix on the VM (update-module.sh ${CONSUMER}), alloy running, and the pinhole to :3101 in place?" ;;
esac
exit 1
