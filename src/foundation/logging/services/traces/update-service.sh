#!/usr/bin/env bash
#
# TAPPaaS logging:traces — update (ADR-046 P6). As install; said at [Debug].
#
# Usage: update-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

debug "  logging:traces: ${CONSUMER}"
traces_converge
