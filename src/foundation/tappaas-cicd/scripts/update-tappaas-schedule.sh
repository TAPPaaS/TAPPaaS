#!/usr/bin/env bash
# update-tappaas-schedule.sh — render update-tappaas.timer from site.json (ADR-017 D2).
#
# Run as root by update-tappaas-schedule.service: at boot, after every
# self-rebuild (ADR-017 D3), and when `site-manager site modify` changes the
# schedule. Writes /run/systemd/system/update-tappaas.timer, so the running
# timer is re-derived from site.json every time and nothing persistent can
# drift from it. A schedule of "none" removes the timer. An unusable schedule
# leaves the current timer as it is and fails this unit, so it shows.
#
# It also renders cmdb-sweep.timer beside it (ADR-040 D15): the discovery sweep
# runs every night, an hour before the update window's hour, so an update runs
# against a fresh actual; 01:00 for a site with no scheduled update.
#
# And health-assess.timer (ADR-041 D2), every site.json health.assessInterval
# minutes (1 to 60, default 5), whatever the update's schedule says.
#
# Usage: update-tappaas-schedule.sh [--dry-run]    (--dry-run prints the unit)
#
# Environment (tests): TAPPAAS_SITE_JSON, TAPPAAS_TIMER_FILE, TAPPAAS_NO_SYSTEMCTL=1

set -euo pipefail
# Runs as root: tools from root-only directories, never the operator's ~/bin.
export PATH=/run/wrappers/bin:/run/current-system/sw/bin

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/update-schedule.sh
. "${_here}/../lib/update-schedule.sh"

SITE="${TAPPAAS_SITE_JSON:-/home/tappaas/config/site.json}"
TIMER="${TAPPAAS_TIMER_FILE:-/run/systemd/system/update-tappaas.timer}"
SWEEP_TIMER="$(dirname "${TIMER}")/cmdb-sweep.timer"
HEALTH_TIMER="$(dirname "${TIMER}")/health-assess.timer"
DRY_RUN=0
for a in "$@"; do
    case "${a}" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "update-tappaas-schedule: unknown option: ${a}" >&2; exit 2 ;;
    esac
done

sysctl_() { [[ "${TAPPAAS_NO_SYSTEMCTL:-0}" == "1" ]] || systemctl "$@"; }

# health-assess.timer: first, so a broken update schedule leaves the site's
# health running. An interval that cannot be used is the default, and says so.
render_health_timer() {
    local minutes
    minutes="$(jq -r '.health.assessInterval // 5' "${SITE}" 2>/dev/null || echo 5)"
    if ! [[ "${minutes}" =~ ^[0-9]+$ ]] || (( 10#${minutes} < 1 || 10#${minutes} > 60 )); then
        echo "update-tappaas-schedule: health.assessInterval ${minutes} is unusable — using 5 minutes" >&2
        minutes=5
    fi
    minutes=$((10#${minutes}))
    mkdir -p "$(dirname "${HEALTH_TIMER}")"
    cat > "${HEALTH_TIMER}.tmp" <<UNIT
# Rendered by update-tappaas-schedule.sh (ADR-041 D2). Do not edit.
[Unit]
Description=Assess the site's health every ${minutes} minutes

[Timer]
OnCalendar=*:0/${minutes}
Persistent=false
Unit=health-assess.service
UNIT
    mv -f "${HEALTH_TIMER}.tmp" "${HEALTH_TIMER}"
    sysctl_ daemon-reload
    sysctl_ restart health-assess.timer
    echo "update-tappaas-schedule: health-assess.timer → every ${minutes} minutes"
}
[[ "${DRY_RUN}" -eq 1 ]] || render_health_timer

schedule="$(jq -c '.updateSchedule // null' "${SITE}" 2>/dev/null || echo null)"
if ! calendar="$(update_schedule_oncalendar "${schedule}")"; then
    echo "update-tappaas-schedule: updateSchedule ${schedule} is unusable — timer left as it is" >&2
    exit 1
fi

# cmdb-sweep.timer: nightly, whatever the update's frequency, an hour before
# its hour (the calendar's last field). Persistent, unlike the update: a night
# the mothership was down is made up, and a sweep changes nothing.
render_sweep_timer() {
    local hour=2 at
    [[ "${calendar}" =~ ([0-9]{2}):00:00$ ]] && hour=$((10#${BASH_REMATCH[1]}))
    at="$(printf '%02d:00:00' $(( (hour + 23) % 24 )))"
    mkdir -p "$(dirname "${SWEEP_TIMER}")"
    cat > "${SWEEP_TIMER}.tmp" <<UNIT
# Rendered by update-tappaas-schedule.sh (ADR-040 D15). Do not edit.
[Unit]
Description=Nightly CMDB discovery sweep (${at})

[Timer]
OnCalendar=*-*-* ${at}
Persistent=true
Unit=cmdb-sweep.service
UNIT
    mv -f "${SWEEP_TIMER}.tmp" "${SWEEP_TIMER}"
    sysctl_ daemon-reload
    sysctl_ restart cmdb-sweep.timer
    echo "update-tappaas-schedule: cmdb-sweep.timer → OnCalendar=*-*-* ${at}"
}
[[ "${DRY_RUN}" -eq 1 ]] || render_sweep_timer

if [[ -z "${calendar}" ]]; then
    echo "update-tappaas-schedule: updateSchedule ${schedule} — no scheduled update; timer removed"
    [[ "${DRY_RUN}" -eq 1 ]] && exit 0
    sysctl_ stop update-tappaas.timer 2>/dev/null || true
    rm -f "${TIMER}"
    sysctl_ daemon-reload
    exit 0
fi

if [[ "${TAPPAAS_NO_SYSTEMCTL:-0}" != "1" ]] && ! systemd-analyze calendar "${calendar}" >/dev/null 2>&1; then
    echo "update-tappaas-schedule: systemd rejects OnCalendar '${calendar}' — timer left as it is" >&2
    exit 1
fi

unit="$(cat <<EOF
# Rendered by update-tappaas-schedule.sh from site.json .updateSchedule ${schedule}
# (ADR-017 D2). Do not edit: it is rewritten at boot and on every schedule change.
[Unit]
Description=Scheduled TAPPaaS update (${calendar})

[Timer]
OnCalendar=${calendar}
Persistent=false
Unit=update-tappaas.service
EOF
)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '%s\n' "${unit}"
    exit 0
fi
mkdir -p "$(dirname "${TIMER}")"
printf '%s\n' "${unit}" > "${TIMER}.tmp" && mv -f "${TIMER}.tmp" "${TIMER}"
sysctl_ daemon-reload
sysctl_ restart update-tappaas.timer
echo "update-tappaas-schedule: update-tappaas.timer → OnCalendar=${calendar} (Persistent=false)"

# Resume a sweep that a planned mothership reboot cut short (#744).
#
# NOT a catch-up. ADR-017 D1 keeps Persistent=false on purpose: a tick missed
# while the host was unexpectedly down must not fire at boot, because whatever
# took the host down could be compounded by running again immediately. This is
# the other case — tappaas-self-rebuild.sh rebooted us itself, deliberately, to
# take a nixpkgs release move, and it succeeded. The modules were never touched.
# Waiting for the next window skipped a full day of updates on the staging site
# and left a guest's dead Grafana unfixable for two further days, with the fix
# already sitting in the site's own checkout.
#
# The marker is consumed BEFORE the sweep starts, so a sweep that dies for some
# other reason cannot loop: one interrupted run earns exactly one resume.
resume_marker="${CONFIG_DIR:-/home/tappaas/config}/.update-resume"
if [[ -f "${resume_marker}" ]]; then
    reason="$(sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${resume_marker}" | head -1)"
    rm -f "${resume_marker}"
    echo "update-tappaas-schedule: resuming the sweep interrupted by ${reason:-a planned reboot}"
    if [[ "${TAPPAAS_NO_SYSTEMCTL:-0}" == "1" ]] || [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "update-tappaas-schedule: (would start update-tappaas.service)"
    else
        # --no-block: this unit runs during boot, and the sweep takes many
        # minutes; blocking here would hold up timers.target.
        systemctl start --no-block update-tappaas.service \
            || echo "update-tappaas-schedule: could not start the resumed sweep — it waits for its next window" >&2
    fi
fi
