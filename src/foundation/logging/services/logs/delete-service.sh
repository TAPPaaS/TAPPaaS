#!/usr/bin/env bash
#
# TAPPaaS logging:logs — delete (#770)
#
# The consumer stops shipping: its pinhole to the push receiver goes with a
# rules reconcile, a Debian VM's or container's Alloy client is removed here, and
# update-os.sh removes a NixOS guest's /etc/nixos/tappaas-logging.nix on its next
# OS update (no logging, or no declaration, means no fragment).
#
# Usage: delete-service.sh <consumer-module> [--dry-run]

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh" "$@"

info "logging:logs: ${CONSUMER} stops shipping its journal"
logs_reconcile_consumer_rules
logs_remove_client
logs_apply_alerts --without
# Its push credential goes too (#165 §1): logging stops accepting it at once.
# shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
. "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
_host="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
# The credential also carries the guest's own performance numbers, from the
# same Alloy client — which goes with this delete. Its node keeps reporting the
# guest's outside view (CPU, memory, disk, network), which needs no credential
# of the guest's; say so, so the operator is not surprised by half the charts.
if [[ -f "${METRICS_SHIPPING_LIB:-/home/tappaas/bin/metrics-shipping.sh}" ]]; then
    # shellcheck source=../../../tappaas-cicd/lib/metrics-shipping.sh
    . "${METRICS_SHIPPING_LIB:-/home/tappaas/bin/metrics-shipping.sh}"
    if metrics_wanted && [[ "$(log_shipping_syslog_kind "${CONSUMER}")" == "" ]] \
        && [[ "$(metrics_effective "${CONSUMER}" 2>/dev/null | jq -r .level)" != off ]]; then
        info "  ${CONSUMER}'s own performance numbers stop with its journal client; its node keeps reporting its CPU, memory, disk and network"
    fi
fi
if [[ "${DRY_RUN}" -eq 0 && "${_host:-${CONSUMER}}" =~ ^[A-Za-z0-9-]+$ ]]; then
    rm -f "${LOG_SHIPPING_CRED_DIR}/${_host:-${CONSUMER}}"
    log_shipping_sync_logging || warn "  could not update logging's password file"
fi
