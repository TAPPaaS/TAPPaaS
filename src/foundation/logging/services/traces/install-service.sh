#!/usr/bin/env bash
#
# TAPPaaS logging:traces — install (ADR-046 P6)
#
# Usage: install-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "  ${GN}✓${CL} logging:traces: ${CONSUMER} may push spans to logging (:3120); the store runs while a CI is raised to trace"
traces_converge
