# shellcheck shell=bash
# Sourced by the logging:metrics service scripts (ADR-046 P1).
#
# Usage: <script> <consumer-module> [--dry-run] [--force]
#
# Who the consumer is decides what pushes:
#   node   a pvehost instance: the cluster's external metric server and the
#          nodes' sampler (one cluster-wide setting, tappaas-metrics-target pve)
#   pbs    the PBS instance: its InfluxDB metric server (… pbs)
#   guest  anything else: its push credential and identity now; its own Alloy
#          pipeline comes with the performance levels per module
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
METRICS_TARGET="${METRICS_TARGET_BIN:-${TAPPAAS_BIN:-/home/tappaas/bin}/tappaas-metrics-target.sh}"

metrics_kind() {
    [[ "$(log_shipping_syslog_kind "${CONSUMER}")" == node ]] && { echo node; return; }
    [[ "$(_ms_pbs_instance 2>/dev/null)" == "${CONSUMER}" ]] && { echo pbs; return; }
    echo guest
}

# The consumer's host label in the store: a node's name, else its vmname.
metrics_host() {
    local h; h="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
    echo "${h:-${CONSUMER}}"
}

# Credentials, identities and the target the consumer pushes through.
metrics_converge() {
    local kind out
    kind="$(metrics_kind)"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        debug "  [dry-run] metrics: ${CONSUMER} (${kind}) at performance level $(metrics_level)"
        return 0
    fi
    [[ "${kind}" == guest ]] && { log_shipping_password "$(metrics_host)" >/dev/null || warn "  could not make the push credential for ${CONSUMER}"; }
    out="$(metrics_sync_logging 2>&1)" && debug "  ${out//$'\n'/; }" \
        || warn "  could not write the metrics identities to logging — ${CONSUMER}'s numbers carry no identity until they are"
    case "${kind}" in
        node|pbs)
            # In sync, apply says nothing: that is success, so no bare `[[ ]] &&`
            # here — as the function's last command it would return 1.
            if out="$("${METRICS_TARGET}" "${kind/node/pve}" apply 2>&1)"; then
                if [[ -n "${out}" ]]; then debug "  ${out//$'\n'/; }"; fi
            else
                warn "  ${CONSUMER}: the metric server is not set: ${out//$'\n'/; }"
            fi ;;
    esac
}
