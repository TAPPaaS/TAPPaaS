#!/usr/bin/env bash
#
# TAPPaaS logging:logs — delete (#770)
#
# The consumer stops shipping: its pinhole to the push receiver goes with a
# rules reconcile, and update-os.sh removes /etc/nixos/tappaas-logging.nix on its
# next OS update (no logging, or no declaration, means no fragment).
#
# Usage: delete-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "logging:logs: ${CONSUMER} stops shipping its journal"
logs_reconcile_consumer_rules
