#!/usr/bin/env bash
# 0003-update-schedule-object.sh — updateSchedule becomes a named object
#
# Introduced: 2.1 (Wave 0, G0.1).  Required by: ADR-017 D7, named as 0003 by ADR-025 D12.
# Touches: config/site.json (only).
# Reversible: yes — restore config/.migrations/backup/0003/site.json.
#
# WHY. The triple's second slot is read only for `weekly` and `monthly`. A site
# that says ["daily", "Tuesday", 2] is stating something no reader has ever
# honoured — the reference site has carried exactly that for months, updating
# every day — and nothing told anyone. A named object cannot express it:
#
#   ["none",    *,          *]  →  {"frequency": "none"}
#   ["daily",   <weekday>,  H]  →  {"frequency": "daily",   "hour": H}
#   ["weekly",  "Tuesday",  H]  →  {"frequency": "weekly",  "weekday": "Tuesday",  "hour": H}
#   ["monthly", "Thursday", H]  →  {"frequency": "monthly", "weekday": "Thursday", "hour": H}
#
# A weekday dropped by the first two rules is REPORTED, not discarded quietly:
# it is the only trace of what the operator believed they had asked for.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): an unknown frequency, a
# weekday that is not a day name, an hour outside 0-23, and an array shorter
# than three. That last one reads as "daily at 02:00" today by defaulting, so
# ["weekly"] silently means daily — a person should look at that, not a script.
#
# Usage: 0003-update-schedule-object.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0003}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0003: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0003: $*"; }
warn() { echo -e "\033[33m[Warning]\033[m 0003: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0003: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"

kind="$(jq -r '.updateSchedule | type' "${SITE}" 2>/dev/null || echo null)"
case "${kind}" in
    null)
        say "site.json has no updateSchedule — nothing to migrate"; exit 0 ;;
    object)
        say "updateSchedule is already an object — nothing to migrate"; exit 0 ;;
    array) : ;;
    *)     stop "updateSchedule is a ${kind}, which is neither the triple nor the object — a person should look at this" ;;
esac

[[ "$(jq -r '.updateSchedule | length' "${SITE}")" -ge 3 ]] \
    || stop "updateSchedule $(jq -c .updateSchedule "${SITE}") is shorter than [frequency, weekday, hour]; it currently reads as daily at 02:00 by defaulting, which is unlikely to be what was meant — set it with 'site-manager site modify' and re-run"

freq="$(jq -r '.updateSchedule[0] // "" | ascii_downcase' "${SITE}")"
weekday_raw="$(jq -r '.updateSchedule[1] // ""' "${SITE}")"
hour_raw="$(jq -r '.updateSchedule[2]' "${SITE}")"

case "${freq}" in
    none|daily|weekly|monthly) : ;;
    *) stop "updateSchedule frequency '${freq}' is not none/daily/weekly/monthly" ;;
esac

# The hour: a JSON number, or a numeric string as some hand-edited sites carry.
[[ "${hour_raw}" =~ ^[0-9]{1,2}$ ]] || stop "updateSchedule hour '${hour_raw}' is not a number 0-23"
hour=$((10#${hour_raw}))
(( hour <= 23 )) || stop "updateSchedule hour '${hour_raw}' is not a number 0-23"

# The weekday, normalized to the capitalized day name the object form carries.
weekday=""
case "$(printf '%s' "${weekday_raw}" | tr '[:upper:]' '[:lower:]')" in
    monday)    weekday=Monday ;;    tuesday)  weekday=Tuesday ;;
    wednesday) weekday=Wednesday ;; thursday) weekday=Thursday ;;
    friday)    weekday=Friday ;;    saturday) weekday=Saturday ;;
    sunday)    weekday=Sunday ;;
    ""|null)   weekday="" ;;
    *)         stop "updateSchedule weekday '${weekday_raw}' is not a day name" ;;
esac

case "${freq}" in
    weekly|monthly)
        [[ -n "${weekday}" ]] \
            || stop "updateSchedule is '${freq}' with no weekday, so no update has been running; set one with 'site-manager site modify' and re-run"
        new="$(jq -n --arg f "${freq}" --arg w "${weekday}" --argjson h "${hour}" \
            '{frequency: $f, weekday: $w, hour: $h}')" ;;
    daily)
        [[ -z "${weekday}" ]] \
            || warn "the weekday '${weekday_raw}' is dropped: it has never been read under 'daily' — this site updates every day at ${hour}:00"
        new="$(jq -n --arg f "${freq}" --argjson h "${hour}" '{frequency: $f, hour: $h}')" ;;
    none)
        [[ -z "${weekday}" ]] \
            || warn "the weekday '${weekday_raw}' is dropped: nothing is scheduled under 'none'"
        new="$(jq -n '{frequency: "none"}')" ;;
esac

if [[ "${CHECK}" -eq 1 ]]; then
    say "would rewrite updateSchedule $(jq -c .updateSchedule "${SITE}") → $(jq -c . <<<"${new}") in ${SITE}"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"

tmp="${SITE}.0003.tmp"
jq --argjson s "${new}" '.updateSchedule = $s' "${SITE}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — ${SITE} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten site.json is not valid JSON — ${SITE} is unchanged"; }
# Ownership is the invariant #525 is about: a root-owned config drops out of the
# sweep. cp -p onto the temp copy keeps the mode; mv keeps the owner of the
# file being replaced only if we do not cross filesystems, and we do not.
chmod --reference="${BACKUP_DIR}/site.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${SITE}"
say "updateSchedule → $(jq -c . <<<"${new}")"
note "backup: ${BACKUP_DIR}/site.json"
