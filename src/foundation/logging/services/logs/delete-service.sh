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
# Its push credential goes too (#165 §1): logging stops accepting it at once.
# shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
. "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
_host="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
if [[ "${DRY_RUN}" -eq 0 && "${_host:-${CONSUMER}}" =~ ^[A-Za-z0-9-]+$ ]]; then
    rm -f "${LOG_SHIPPING_CRED_DIR}/${_host:-${CONSUMER}}"
    log_shipping_sync_logging || warn "  could not update logging's password file"
fi
