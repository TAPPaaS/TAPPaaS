#!/usr/bin/env bash
#
# TAPPaaS logging:traces — test (ADR-046 P6): the trace store is in the state
# the raises ask for. A consumer's own spans exist only while it is raised.
#
# Usage: test-service.sh <consumer-module>

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "  logging:traces tests for ${BL}${CONSUMER}${CL}"
s="$(metrics_traces_state 2>/dev/null || echo unknown)"
case "${s}" in
    in-sync|absent) info "    ${GN}✓${CL} the trace store matches the raises ($(_ms_traces_wanted))" ;;
    unknown) warn "    the logging VM did not answer — cannot tell the trace store's state" ;;
    *) error "    ✗ the trace store does not match the raises — tappaas-metrics-target.sh traces apply"; exit 1 ;;
esac
