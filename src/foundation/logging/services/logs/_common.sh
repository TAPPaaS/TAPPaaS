# Sourced by the logging:logs service scripts (#770).
#
# Usage: <script> <consumer-module> [--dry-run] [--force]
# --force is accepted and ignored: module-manager reconcile --force forwards it
# to every provider, and there is nothing here to authorize.

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

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
