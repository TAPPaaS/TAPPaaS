#!/usr/bin/env bash
#
# TAPPaaS logging:logs — install (#770)
#
# A consumer's journal ships to Loki through a journal client (lib/log-shipping.sh):
# on NixOS the baseline's, which update-os.sh writes as /etc/nixos/tappaas-logging.nix
# while the consumer declares logging:logs and logging is deployed; on a Debian VM
# or a container, Alloy with the same pipeline, applied here (#903). This also
# reconciles the consumer's pinhole to the push receiver — which matters when
# logging arrives after the consumer.
#
# Usage: install-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "  ${GN}✓${CL} logging:logs: ${CONSUMER} ships its journal to logging (push receiver :3101)"
logs_reconcile_consumer_rules
logs_sync_credentials
logs_apply_client
logs_apply_alerts
