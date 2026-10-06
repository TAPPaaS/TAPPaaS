#!/usr/bin/env bash
#
# TAPPaaS logging:logs — update (#770)
#
# A consumer's journal ships to Loki through the NixOS baseline's journal client,
# which update-os.sh writes as /etc/nixos/tappaas-logging.nix while the consumer
# declares logging:logs and logging is deployed (lib/log-shipping.sh). Nothing to
# do on the logging side; this reconciles the consumer's pinhole to the push
# receiver — which matters when logging arrives after the consumer.
#
# Usage: update-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "logging:logs: ${CONSUMER} ships its journal to logging (push receiver :3101)"
logs_reconcile_consumer_rules
logs_sync_credentials
info "  the journal client is applied with the consumer's OS update (update-module.sh ${CONSUMER})"
