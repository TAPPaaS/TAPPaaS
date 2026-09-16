# shellcheck shell=bash
# update-schedule.sh — site.json `updateSchedule` → systemd OnCalendar (ADR-017 D1/D2).
#
# One mapping, used by the timer renderer (scripts/update-tappaas-schedule.sh)
# and by `site-manager validate` (validate-site.sh), so the schedule that is
# checked is the schedule that runs. It keeps the semantics of the in-process
# gate it replaces (update-tappaas main.py should_update_now):
#   missing or short triple            → daily at 02:00
#   ["none", …]                        → no timer
#   ["daily",   <ignored>, H]          → *-*-* H:00:00   (a weekday here is inert)
#   ["weekly",  "Tuesday", H]          → Tue *-*-* H:00:00
#   ["monthly", "Tuesday", H]          → Tue *-*-01..07 H:00:00   (first Tuesday)
#   weekly/monthly without a weekday   → no timer (the gate never ran it either)
#
# THE SHAPE, since ADR-017 D7 / migration 0003. `updateSchedule` is a named
# object, because the triple's second slot is read only for weekly and monthly
# and a site that writes ["daily", "Tuesday", 2] is stating something no reader
# has ever honoured:
#
#   {"frequency": "none"}
#   {"frequency": "daily",   "hour": 2}
#   {"frequency": "weekly",  "weekday": "Tuesday",  "hour": 2}
#   {"frequency": "monthly", "weekday": "Thursday", "hour": 2}
#
# BOTH forms are read here, deliberately and for good. Migration 0003 rewrites
# site.json before the rebuild, so in the normal run the object is all anything
# sees — but a restored backup, a site rolled back to an earlier release, or a
# hand-edited file can still hold a triple, and the reader that refuses one
# would take that site's updates away. The legacy branch costs a case
# statement; retiring it is a release decision (ADR-025 D10), not this file's.

# update_schedule_oncalendar <updateSchedule JSON>
# Prints the OnCalendar expression, or nothing for "no timer". Diagnostics go
# to stderr as "warn: …" lines; the return code is 0 unless the value is unusable.
update_schedule_oncalendar() {
    local json="${1:-null}" kind freq weekday hour day
    kind="$(jq -r 'type' <<<"${json}" 2>/dev/null || echo null)"
    case "${kind}" in
        object)
            # The named form. A missing hour is 02:00, as it has always been;
            # a missing frequency is the same "nothing usable here" as a
            # missing field, handled below.
            freq="$(jq -r '.frequency // "" | ascii_downcase' <<<"${json}")"
            weekday="$(jq -r '.weekday // "" | ascii_downcase' <<<"${json}")"
            hour="$(jq -r '.hour // 2' <<<"${json}")"
            if [[ -z "${freq}" ]]; then
                echo "warn: updateSchedule has no frequency — using daily at 02:00" >&2
                printf '*-*-* 02:00:00\n'
                return 0
            fi
            # D7 requires `hour` to be written down and REFUSES `weekday` where
            # no reader honours it. Both are reported here, which is how
            # `site-manager validate` sees them — but neither stops the render:
            # leaving a site with no timer over a field it could default is a
            # worse failure than the field being wrong.
            if [[ "$(jq -r 'has("hour")' <<<"${json}")" != "true" ]]; then
                echo "warn: updateSchedule has no hour — using 02:00; ADR-017 D7 wants the hour a site updates at written down" >&2
            fi
            if [[ -n "${weekday}" && ( "${freq}" == daily || "${freq}" == none ) ]]; then
                echo "warn: updateSchedule has a weekday under '${freq}', where no reader honours it — remove it (ADR-017 D7)" >&2
            fi
            ;;
        array)
            if [[ "$(jq -r 'length' <<<"${json}")" -lt 3 ]]; then
                echo "warn: updateSchedule is not a [frequency, weekday, hour] triple — using daily at 02:00" >&2
                printf '*-*-* 02:00:00\n'
                return 0
            fi
            echo "warn: updateSchedule is still the legacy triple — 'site-manager validate' names the migration that renames it (0003)" >&2
            freq="$(jq -r '.[0] // "" | ascii_downcase' <<<"${json}")"
            weekday="$(jq -r '.[1] // "" | ascii_downcase' <<<"${json}")"
            hour="$(jq -r '.[2] // 2' <<<"${json}")"
            ;;
        *)
            [[ "${json}" == "null" ]] || echo "warn: updateSchedule is neither an object nor a triple — using daily at 02:00" >&2
            printf '*-*-* 02:00:00\n'
            return 0
            ;;
    esac
    if ! [[ "${hour}" =~ ^[0-9]{1,2}$ ]] || (( 10#${hour} > 23 )); then
        echo "warn: updateSchedule hour '${hour}' is not 0-23" >&2
        return 1
    fi
    hour=$((10#${hour}))   # "08" is eight, not an octal error
    case "${weekday}" in
        monday) day=Mon ;; tuesday) day=Tue ;; wednesday) day=Wed ;; thursday) day=Thu ;;
        friday) day=Fri ;; saturday) day=Sat ;; sunday) day=Sun ;;
        ""|null) day="" ;;
        *) echo "warn: updateSchedule weekday '${weekday}' is not a day name" >&2; return 1 ;;
    esac
    case "${freq}" in
        none)
            [[ -z "${day}" ]] || echo "warn: updateSchedule weekday '${weekday}' is inert under 'none'" >&2
            return 0 ;;
        daily)
            [[ -z "${day}" ]] || echo "warn: updateSchedule weekday '${weekday}' is inert under 'daily' — the update runs every day" >&2
            printf '*-*-* %02d:00:00\n' "${hour}" ;;
        weekly|monthly)
            if [[ -z "${day}" ]]; then
                echo "warn: updateSchedule '${freq}' has no weekday — no update runs" >&2
                return 0
            fi
            if [[ "${freq}" == weekly ]]; then
                printf '%s *-*-* %02d:00:00\n' "${day}" "${hour}"
            else
                printf '%s *-*-01..07 %02d:00:00\n' "${day}" "${hour}"
            fi ;;
        *)
            echo "warn: updateSchedule frequency '${freq}' is not none/daily/weekly/monthly" >&2
            return 1 ;;
    esac
}
