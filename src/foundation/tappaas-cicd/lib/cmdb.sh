#!/usr/bin/env bash
# cmdb.sh — the bash layer's client of cmdb-controller (ADR-040 D2, D4): thin
# wrappers over the `cmdb` CLI, which spools a report the service cannot take
# (config/.cmdb-spool/) and replays it later (lib/ts/src/cmdb.ts).
#
# Source it:   . "${TAPPAAS_CICD:-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd}/lib/cmdb.sh"
#
#   cmdb_report [file]       a report (JSON) from the file or stdin. Never fails
#                            the caller: the CMDB is a record, never a gate. A
#                            refused report is a warning on stderr.
#   cmdb_query <class> [cmdb query options]   the objects, as JSON
#   cmdb_show <object> [cmdb show options]    one object, as JSON
#   cmdb_available           0 when the service answers
#
# CMDB_BIN overrides the CLI (tests).

_cmdb() { "${CMDB_BIN:-cmdb}" "$@"; }

cmdb_available() {
    _cmdb class list --json >/dev/null 2>&1
}

cmdb_report() {
    local out rc=0
    if [[ -n "${1:-}" ]]; then
        out="$(_cmdb report --json --file "$1" 2>&1)" || rc=$?
    else
        out="$(_cmdb report --json 2>&1)" || rc=$?
    fi
    if [[ "${rc}" -ne 0 ]]; then
        echo "[Warning] cmdb: report not recorded (rc ${rc}): ${out}" >&2
    fi
    return 0
}

cmdb_query() {
    local cls="$1"; shift
    _cmdb query "${cls}" --json "$@"
}

cmdb_show() {
    local ref="$1"; shift
    _cmdb show "${ref}" --json "$@"
}
