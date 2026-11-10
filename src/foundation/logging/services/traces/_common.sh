# shellcheck shell=bash
# Sourced by the logging:traces service scripts (ADR-046 P6).
#
# Usage: <script> <consumer-module> [--dry-run] [--force]
#
# A consumer pushes spans with its push credential (the one its logs and
# metrics use); the logging VM's trace store runs only while some CI is raised
# to trace. What the consumer runs to send them is its own (its declaration's
# traces.otlp); this service makes sure the credential and the pinhole exist.
set -euo pipefail
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"

CONSUMER="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) shift ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "${CONSUMER}" ]] || die "unexpected argument: $1"; CONSUMER="$1"; shift ;;
    esac
done
[[ -n "${CONSUMER}" ]] || die "Usage: $0 <consumer-module> [--dry-run]"

# shellcheck source=../../../tappaas-cicd/lib/metrics-shipping.sh
. "${METRICS_SHIPPING_LIB:-${TAPPAAS_BIN:-/home/tappaas/bin}/metrics-shipping.sh}"

traces_host() {
    local h; h="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
    echo "${h:-${CONSUMER}}"
}

traces_converge() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then debug "  [dry-run] logging:traces: credential for $(traces_host)"; return 0; fi
    log_shipping_password "$(traces_host)" >/dev/null || { warn "  could not make the push credential for ${CONSUMER}"; return 0; }
    metrics_sync_logging >/dev/null 2>&1 || warn "  could not write the identities to logging — ${CONSUMER}'s spans carry no CI id until they are"
}
