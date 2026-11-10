#!/usr/bin/env bash
#
# TAPPaaS logging:metrics — update (ADR-046 P1). As install; said at [Debug].
#
# Usage: update-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

debug "  logging:metrics: ${CONSUMER} at performance level $(metrics_level)"
metrics_converge
