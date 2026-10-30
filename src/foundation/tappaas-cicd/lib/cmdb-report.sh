#!/usr/bin/env bash
# cmdb-report.sh — what the bash managers' `report` verbs and changing verbs
# share on top of lib/cmdb.sh (ADR-040 D4): the console's job on a change, and
# sending the reports a manager's filter built, each on its own, so a report
# the controller refuses (an unresolved reference) takes nothing else with it.
#
# Source it:   . "${TAPPAAS_CICD:-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd}/lib/cmdb-report.sh"
#
#   cmdb_change_head <verb>     {kind: "change", verb, job, actor} as JSON:
#                               job is TAPPAAS_JOB_ID, else TAPPAAS_JOB (the console's Activity
#                               id), actor TAPPAAS_ACTOR, else $USER
#   cmdb_send_reports           a JSON array of reports on stdin, each sent
#                               with cmdb_report. Never fails the caller.
#                               TAPPAAS_CMDB=off sends nothing.
#   cmdb_report_count           "<objects> objects, <relations> relations" of
#                               the array on stdin

_cmdb_report_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cmdb.sh
. "${_cmdb_report_here}/cmdb.sh"

cmdb_change_head() {
    jq -cn --arg verb "$1" --arg job "${TAPPAAS_JOB_ID:-${TAPPAAS_JOB:-}}" --arg actor "${TAPPAAS_ACTOR:-${USER:-}}" \
        '{kind: "change", verb: $verb} + (if $job != "" then {job: $job} else {} end) + (if $actor != "" then {actor: $actor} else {} end)'
}

cmdb_send_reports() {
    local reports r
    reports="$(cat)"
    [[ "${TAPPAAS_CMDB:-}" == off ]] && return 0
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"${reports}" || { echo "[Warning] cmdb: no report to send" >&2; return 0; }
    while IFS= read -r r; do
        [[ -n "${r}" ]] || continue
        printf '%s' "${r}" | cmdb_report
    done < <(jq -c '.[] | select(((.objects // []) | length) + ((.relations // []) | length) > 0)' <<<"${reports}")
    return 0
}

cmdb_report_count() {
    jq -r '"\(map(.objects // [] | length) | add // 0) objects, \(map(.relations // [] | length) | add // 0) relations"'
}
