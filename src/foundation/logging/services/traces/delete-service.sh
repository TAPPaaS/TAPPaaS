#!/usr/bin/env bash
#
# TAPPaaS logging:traces — delete (ADR-046 P6). The credential is logging:logs'
# to remove; a raise on the consumer ends with its own expiry or perf stop.
#
# Usage: delete-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "logging:traces: ${CONSUMER} stops pushing spans"
