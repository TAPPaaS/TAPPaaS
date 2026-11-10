#!/usr/bin/env bash
#
# TAPPaaS logging:metrics — install (ADR-046 P1)
#
# A node's and the PBS's numbers reach the metrics store through their own
# external metric server, set here (and by site-manager's and backup-manager's
# reconcile); a guest gets its credential and identity, its Alloy pipeline comes
# with the per-module levels. Nothing is collected while site.json's
# performance.level is off.
#
# Usage: install-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

case "$(metrics_level)" in
    off) info "  logging:metrics: the site's performance level is off — ${CONSUMER} pushes no numbers" ;;
    *)   info "  ${GN}✓${CL} logging:metrics: ${CONSUMER} pushes its numbers to logging (:3120, level $(metrics_level))" ;;
esac
metrics_converge
