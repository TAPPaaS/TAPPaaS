#!/usr/bin/env bash
#
# tappaas-maintenance.sh — maintenance windows the alert receiver honours.
#
# A window names hosts (or the whole site) and an end time. While it is open,
# tappaas-alert-receiver records a HostSilent from those hosts instead of
# mailing it, and its RESOLVED then finds no ALERT to answer. An update that is
# allowed to restart a guest opens one before it does (converge-lib.sh): the
# guest's own host, or the whole site when the guest is the firewall, since
# every zone's traffic to the logging VM passes through it.
#
# Usage:
#   tappaas-maintenance.sh open  --name N --scope site|HOST[,HOST...] --minutes M [--reason TEXT]
#   tappaas-maintenance.sh close --name N
#   tappaas-maintenance.sh list
#
# The directory is /var/lib/tappaas/maintenance (TAPPAAS_MAINTENANCE_DIR).
# Opening a name that is open already moves its end time; windows that have
# ended are removed by the next open or list.
set -euo pipefail

DIR="${TAPPAAS_MAINTENANCE_DIR:-/var/lib/tappaas/maintenance}"

die() { echo "tappaas-maintenance.sh: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

prune() {
    local now f until
    now="$(date +%s)"
    for f in "${DIR}"/*.json; do
        [[ -e "${f}" ]] || continue
        until="$(jq -r '.until // 0' "${f}" 2>/dev/null || echo 0)"
        [[ "${until%.*}" -lt "${now}" ]] && rm -f "${f}"
    done
    return 0
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
name="" scope="" minutes="" reason=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)    name="${2:-}"; shift 2 ;;
        --scope)   scope="${2:-}"; shift 2 ;;
        --minutes) minutes="${2:-}"; shift 2 ;;
        --reason)  reason="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "${cmd}" in
    open)
        [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "--name: letters, digits, . _ -"
        [[ "${minutes}" =~ ^[0-9]+$ && "${minutes}" -gt 0 ]] || die "--minutes: a positive whole number"
        [[ -n "${scope}" ]] || die "--scope: site, or a comma list of hosts"
        mkdir -p "${DIR}"
        prune
        until=$(( $(date +%s) + minutes * 60 ))
        if [[ "${scope}" == "site" ]]; then
            scope_json='"site"'
        else
            scope_json="$(printf '%s' "${scope}" | jq -R -c 'split(",") | map(select(length > 0))')"
        fi
        tmp="$(mktemp "${DIR}/.${name}.XXXXXX")"
        jq -n --arg n "${name}" --argjson s "${scope_json}" --argjson u "${until}" \
              --arg r "${reason:-maintenance}" --arg o "$(date -Is)" \
              '{name: $n, scope: $s, until: $u, reason: $r, opened: $o}' > "${tmp}"
        mv "${tmp}" "${DIR}/${name}.json"
        ;;
    close)
        [[ -n "${name}" ]] || die "--name is required"
        rm -f "${DIR}/${name}.json"
        ;;
    list)
        [[ -d "${DIR}" ]] || exit 0
        prune
        for f in "${DIR}"/*.json; do
            [[ -e "${f}" ]] || continue
            jq -r '"\(.name)\t\(if .scope == "site" then "site" else (.scope | join(",")) end)\tuntil \(.until | todate)\t\(.reason)"' "${f}"
        done
        ;;
    *) usage >&2; exit 2 ;;
esac
