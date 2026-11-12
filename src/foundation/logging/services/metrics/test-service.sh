#!/usr/bin/env bash
#
# TAPPaaS logging:metrics — test (ADR-046 P1)
#
# The consumer's numbers are in the store: a series with host=<its name> and a
# tappaas_ci_id in the last 5 minutes, asked of the query port (admin
# credential) from the mothership. A guest pushes nothing of its own yet, and
# nothing is expected while the site's performance level is off.
#
# Usage: test-service.sh <consumer-module>

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "  logging:metrics tests for ${BL}${CONSUMER}${CL}"
KIND="$(metrics_kind)"
if [[ "$(metrics_level)" == off ]]; then
    info "    the site's performance level is off — no numbers expected from ${CONSUMER}"; exit 0
fi
if [[ "${KIND}" == guest ]]; then
    info "    ${CONSUMER} pushes no numbers of its own yet (the node reports its outside view)"; exit 0
fi
HOST="$(metrics_host)"
n="$(metrics_curl_admin -fsS --max-time 15 -G "$(metrics_query_url)/api/v1/query" \
        --data-urlencode "query=count(count_over_time({host=\"${HOST}\",tappaas_ci_id!=\"\"}[5m]))" 2>/dev/null \
     | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "")"
if [[ -z "${n}" ]]; then
    warn "    the metrics store did not answer at $(metrics_query_url) — cannot verify ${HOST}'s numbers"; exit 0
fi
if [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]; then
    info "    ${GN}✓${CL} ${HOST}'s numbers are in the store (${n} series in 5 min, each with its identity)"; exit 0
fi
case "${KIND}" in
    node) error "    ✗ no series from host=${HOST} with an identity in 5 min — is the metric server set? (tappaas-metrics-target.sh pve status)" ;;
    pbs)  error "    ✗ no series from host=${HOST} with an identity in 5 min — is PBS's metric server set? (tappaas-metrics-target.sh pbs status)" ;;
esac
exit 1
