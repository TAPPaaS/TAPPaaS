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
# The object form of ADR-017 D7 ships with the G0.1 migration runner.

# update_schedule_oncalendar <updateSchedule JSON>
# Prints the OnCalendar expression, or nothing for "no timer". Diagnostics go
# to stderr as "warn: …" lines; the return code is 0 unless the value is unusable.
update_schedule_oncalendar() {
    local json="${1:-null}" freq weekday hour day
    if [[ "$(jq -r 'type' <<<"${json}" 2>/dev/null)" != "array" ]] \
       || [[ "$(jq -r 'length' <<<"${json}")" -lt 3 ]]; then
        [[ "${json}" == "null" ]] || echo "warn: updateSchedule is not a [frequency, weekday, hour] triple — using daily at 02:00" >&2
        printf '*-*-* 02:00:00\n'
        return 0
    fi
    freq="$(jq -r '.[0] // "" | ascii_downcase' <<<"${json}")"
    weekday="$(jq -r '.[1] // "" | ascii_downcase' <<<"${json}")"
    hour="$(jq -r '.[2] // 2' <<<"${json}")"
    if ! [[ "${hour}" =~ ^[0-9]+$ ]] || (( hour > 23 )); then
        echo "warn: updateSchedule hour '${hour}' is not 0-23" >&2
        return 1
    fi
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
