#!/usr/bin/env bash
#
# TAPPaaS logging:metrics — delete (ADR-046 P1)
#
# The PBS instance's metric server goes with it. A node leaving does not take
# the cluster's metric server away while other nodes stay: it is one setting
# for the cluster, removed by level off or by logging's delete. A guest's
# identity goes with the next sync; its credential is logging:logs' to remove.
#
# Usage: delete-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "logging:metrics: ${CONSUMER} stops pushing numbers"
[[ "${DRY_RUN}" -eq 1 ]] && { debug "  [dry-run] remove ${CONSUMER}'s metric server"; exit 0; }
if [[ "$(metrics_kind)" == pbs ]]; then
    out="$(remove_metrics_pbs 2>&1)" && debug "  ${out}" || warn "  could not remove PBS's metric server: ${out}"
fi
metrics_sync_logging >/dev/null 2>&1 || true
