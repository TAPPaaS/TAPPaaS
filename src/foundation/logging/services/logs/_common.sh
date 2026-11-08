# Sourced by the logging:logs service scripts (#770).
#
# Usage: <script> <consumer-module> [--dry-run] [--force]
# --force is accepted and ignored: module-manager reconcile --force forwards it
# to every provider, and there is nothing here to authorize.

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

_LOGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RULES_UPDATE="${_LOGS_DIR}/../../../network/services/rules/update-service.sh"

# Re-derive the consumer's firewall rules, so its pinhole to the push receiver
# appears (logging installed after it) or goes (logging or the declaration
# removed). Only for a consumer that has network:rules: one without it is in mgmt
# with logging, or has no rules of its own to carry a pinhole.
logs_reconcile_consumer_rules() {
    if ! read_module_config "${CONSUMER}" 2>/dev/null \
            | jq -e '(.dependsOn // []) | index("network:rules") != null' >/dev/null; then
        debug "  ${CONSUMER} has no network:rules — no pinhole to reconcile"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        debug "  [dry-run] network:rules update-service ${CONSUMER}"
        return 0
    fi
    "${_RULES_UPDATE}" "${CONSUMER}" || warn "  could not reconcile ${CONSUMER}'s firewall rules — run: update-module.sh ${CONSUMER}"
}

# The consumer's push credential (#165 §1): made if it has none, and the
# logging VM's password file brought up to date, so the consumer's first push is
# accepted whichever runs first — this, or its OS update writing the client.
logs_sync_credentials() {
    # shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
    . "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
    local host
    # A syslog sender (the firewall, a node) pushes no journal: no credential.
    [[ -n "$(log_shipping_syslog_kind "${CONSUMER}")" ]] && return 0
    host="$(read_module_config "${CONSUMER}" 2>/dev/null | jq -r '.vmname // empty')"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        debug "  [dry-run] push credential for ${host:-${CONSUMER}}, sync to logging"
        return 0
    fi
    log_shipping_password "${host:-${CONSUMER}}" >/dev/null \
        || { warn "  could not make the push credential for ${host:-${CONSUMER}}"; return 0; }
    log_shipping_sync_logging \
        || warn "  could not update logging's password file — ${host:-${CONSUMER}}'s pushes are refused until it is"
}

# The journal client on a Debian VM or a container (#903): Alloy from Grafana's
# Debian package with the NixOS guests' pipeline, applied here on every install
# and update. A NixOS guest gets its fragment with its OS update (update-os.sh);
# a guest this cannot reach as root (HAOS, Windows) gets none.
logs_apply_client() {
    # shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
    . "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
    local t out kind
    kind="$(log_shipping_syslog_kind "${CONSUMER}")"
    if [[ -n "${kind}" ]]; then
        # A syslog sender (D9): the firewall's target, or a node's rsyslog.
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            debug "  [dry-run] syslog forwarding on ${CONSUMER} (${kind})"
            return 0
        fi
        if [[ "${kind}" == opnsense ]]; then out="$(apply_log_shipping_opnsense 2>&1)"; else out="$(apply_log_shipping_node "${CONSUMER}" 2>&1)"; fi \
            && debug "  ${out}" \
            || warn "  could not set ${CONSUMER}'s syslog forwarding — its lines stay on it: ${out}"
        return 0
    fi
    if ! t="$(log_shipping_transport "${CONSUMER}")"; then
        debug "  ${CONSUMER}: no Debian or container journal client to apply here"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        debug "  [dry-run] Alloy journal client on ${CONSUMER} (${t})"
        return 0
    fi
    if out="$(apply_log_shipping_debian "${t}" "${CONSUMER}" 2>&1)"; then
        if [[ "${out}" == *"(changed)"* ]]; then
            info "  ${GN}✓${CL} ${CONSUMER}: $(tail -1 <<<"${out}" | sed 's/ (changed)//') (${t%%:*})"
        else
            debug "  ${CONSUMER}: $(tail -1 <<<"${out}")"
        fi
    else
        warn "  could not apply the journal client on ${CONSUMER} (${t}) — its journal stays on the guest"
        sed 's/^/    /' <<<"${out}" | tail -10 >&2
    fi
}

# Take the client off again (delete). A guest already gone is not an error.
logs_remove_client() {
    # shellcheck source=../../../tappaas-cicd/lib/log-shipping.sh
    . "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
    local t kind
    kind="$(log_shipping_syslog_kind "${CONSUMER}")"
    if [[ -n "${kind}" ]]; then
        [[ "${DRY_RUN}" -eq 1 ]] && { debug "  [dry-run] remove ${CONSUMER}'s syslog forwarding"; return 0; }
        if [[ "${kind}" == opnsense ]]; then remove_log_shipping_opnsense; else remove_log_shipping_node "${CONSUMER}"; fi \
            && debug "  ${CONSUMER}: syslog forwarding removed" \
            || warn "  could not remove ${CONSUMER}'s syslog forwarding"
        return 0
    fi
    t="$(log_shipping_transport "${CONSUMER}")" || return 0
    [[ "${DRY_RUN}" -eq 1 ]] && { debug "  [dry-run] remove the journal client from ${CONSUMER}"; return 0; }
    remove_log_shipping_debian "${t}" >/dev/null 2>&1 \
        && debug "  journal client removed from ${CONSUMER}" \
        || warn "  could not remove the journal client from ${CONSUMER} (${t})"
}

# The consumer's module's alert rules (ADR-039): its <module>-alerts.json put
# into Grafana as one rule group, with the hosts of the module's instances. On
# delete the instance is left out at once, so its silence raises nothing (D4).
_ALERT_RULES="${_LOGS_DIR}/../../../tappaas-cicd/scripts/tappaas-alert-rules.py"
logs_apply_alerts() {
    local mod out; local -a extra=()
    [[ -f "${_ALERT_RULES}" ]] || return 0
    mod="$(module_of "${CONSUMER}" 2>/dev/null)" || { debug "  ${CONSUMER}: module not known — no alert rules applied"; return 0; }
    [[ "${1:-}" == "--without" ]] && extra=(--without "${CONSUMER}")
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        debug "  [dry-run] alert rules of ${mod}"
        return 0
    fi
    if out="$(python3 -I "${_ALERT_RULES}" apply "${mod}" "${extra[@]}" 2>&1)"; then
        case "${out}" in
            *"no rules file"*) debug "  ${mod}: no alert rules of its own" ;;
            *) debug "  ${out}" ;;
        esac
    else
        warn "  alert rules of ${mod} not applied: ${out}"
    fi
}
