#!/usr/bin/env bash
# test-update-schedule.sh — updateSchedule → OnCalendar, and the rendered timer (ADR-017 D1/D2).
# Self-contained: no systemctl (TAPPAAS_NO_SYSTEMCTL=1), temp files only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../../lib/update-schedule.sh
. "${CICD}/lib/update-schedule.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
cal() { update_schedule_oncalendar "$1" 2>/dev/null; }
rc()  { update_schedule_oncalendar "$1" >/dev/null 2>&1; echo $?; }
warns() { update_schedule_oncalendar "$1" 2>&1 >/dev/null; }

ck "daily at 2"                 '*-*-* 02:00:00'          "$(cal '["daily", null, 2]')"
ck "daily, inert weekday"       '*-*-* 03:00:00'          "$(cal '["daily", "Tuesday", 3]')"
[[ "$(warns '["daily", "Tuesday", 3]')" == *"inert under 'daily'"* ]] && ck "the inert weekday is reported" ok ok || ck "the inert weekday is reported" ok missing
ck "weekly Tuesday 2"           'Tue *-*-* 02:00:00'      "$(cal '["weekly", "Tuesday", 2]')"
ck "monthly = first weekday"    'Thu *-*-01..07 02:00:00' "$(cal '["monthly", "Thursday", 2]')"
ck "case-insensitive"           'Sun *-*-* 23:00:00'      "$(cal '["WEEKLY", "sunday", 23]')"
ck "none: no timer"             ''                        "$(cal '["none", null, 2]')"
ck "weekly without weekday: no timer (as the gate)" '' "$(cal '["weekly", null, 2]')"
ck "unset: daily at 2 (as the gate)" '*-*-* 02:00:00'   "$(cal 'null')"
ck "short triple: daily at 2"   '*-*-* 02:00:00'          "$(cal '["weekly"]')"
ck "hour 24 is unusable"        1 "$(rc '["daily", null, 24]')"
ck "unknown weekday is unusable" 1 "$(rc '["weekly", "Funday", 2]')"
ck "unknown frequency is unusable" 1 "$(rc '["hourly", null, 2]')"

# The renderer, against temp files.
R="${CICD}/scripts/update-tappaas-schedule.sh"
d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
export TAPPAAS_SITE_JSON="${d}/site.json" TAPPAAS_TIMER_FILE="${d}/update-tappaas.timer" TAPPAAS_NO_SYSTEMCTL=1
echo '{"updateSchedule": ["weekly", "Tuesday", 4]}' > "${TAPPAAS_SITE_JSON}"
bash "${R}" >/dev/null 2>&1
ck "renders OnCalendar"   'OnCalendar=Tue *-*-* 04:00:00' "$(grep '^OnCalendar=' "${TAPPAAS_TIMER_FILE}")"
ck "Persistent=false"     'Persistent=false'              "$(grep '^Persistent=' "${TAPPAAS_TIMER_FILE}")"
ck "drives the service"   'Unit=update-tappaas.service'   "$(grep '^Unit=' "${TAPPAAS_TIMER_FILE}")"
echo '{"updateSchedule": ["none", null, 2]}' > "${TAPPAAS_SITE_JSON}"
bash "${R}" >/dev/null 2>&1
[[ ! -e "${TAPPAAS_TIMER_FILE}" ]] && ck "none removes the timer" ok ok || ck "none removes the timer" ok present
echo '{"updateSchedule": ["daily", null, 2]}' > "${TAPPAAS_SITE_JSON}"; bash "${R}" >/dev/null 2>&1
echo '{"updateSchedule": ["daily", null, 99]}' > "${TAPPAAS_SITE_JSON}"
bash "${R}" >/dev/null 2>&1; r=$?
ck "an unusable schedule fails the unit" 1 "${r}"
ck "…and leaves the current timer"  'OnCalendar=*-*-* 02:00:00' "$(grep '^OnCalendar=' "${TAPPAAS_TIMER_FILE}")"

# Every unit that execs one of our `#!/usr/bin/env bash` scripts needs a PATH
# with bash: NixOS's default service PATH has none (the renderer failed exit 127
# on its first activation, T3 2026-09-15).
NIX="${CICD}/tappaas-cicd.nix"
for svc in update-tappaas-schedule update-tappaas-failure update-tappaas; do
    blk="$(sed -n "/systemd.services.${svc} = {/,/^  };/p" "${NIX}")"
    if grep -q 'PATH=' <<<"${blk}"; then ck "${svc}.service declares a PATH" ok ok
    else ck "${svc}.service declares a PATH" ok missing; fi
done

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
