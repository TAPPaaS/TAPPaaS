#!/usr/bin/env bash
# cmdb-report.sh — what the bash managers' `report` verbs and changing verbs
# share on top of lib/cmdb.sh (ADR-040 D4): the console's job on a change, and
# sending the reports a manager's filter built, each on its own, so a report
# the controller refuses (an unresolved reference) takes nothing else with it.
#
# Source it:   . "${TAPPAAS_CICD:-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd}/lib/cmdb-report.sh"
#
#   cmdb_current_job            {job, actor} as JSON, the console job a verb
#                               runs in (lib/ts job.ts currentJob): job is
#                               TAPPAAS_JOB_ID (the console's Activity id),
#                               absent outside a job; actor TAPPAAS_ACTOR (the
#                               console user), else the OS user
#   cmdb_change_head <verb>     {kind: "change", verb, job, actor} as JSON
#   cmdb_send_reports           a JSON array of reports on stdin, each sent
#                               with cmdb_report. Never fails the caller.
#                               TAPPAAS_CMDB=off sends nothing.
#   cmdb_end <verb> <class>/<name>...
#                               reports the end of objects a verb did not end:
#                               a test's fixture taken out of config/ by hand.
#                               Never fails the caller.
#   cmdb_report_count           "<objects> objects, <relations> relations" of
#                               the array on stdin

_cmdb_report_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cmdb.sh
. "${_cmdb_report_here}/cmdb.sh"

cmdb_current_job() {
    local actor="${TAPPAAS_ACTOR:-}"
    [[ -n "${actor}" ]] || actor="$(id -un 2>/dev/null)" || true
    [[ -n "${actor}" ]] || actor="${USER:-unknown}"
    jq -cn --arg job "${TAPPAAS_JOB_ID:-}" --arg actor "${actor}" \
        '(if $job != "" then {job: $job} else {} end) + {actor: $actor}'
}

cmdb_change_head() {
    jq -cn --arg verb "$1" --argjson j "$(cmdb_current_job)" '{kind: "change", verb: $verb} + $j'
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

cmdb_end() {
    local verb="$1"; shift
    jq -cn --argjson head "$(cmdb_change_head "${verb}")" '$ARGS.positional | [$head + {
        source: "cmdb-end",
        objects: map(split("/") | {class: .[0], name: .[1], end: true})
    }]' --args "$@" | cmdb_send_reports
}

cmdb_report_count() {
    jq -r '"\(map(.objects // [] | length) | add // 0) objects, \(map(.relations // [] | length) | add // 0) relations"'
}
