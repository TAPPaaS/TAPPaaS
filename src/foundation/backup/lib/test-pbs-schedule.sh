#!/usr/bin/env bash
#
# Unit tests for the backup SCHEDULE cascade and its job buckets
# (ADR-012 §3.2, D16) — pbs-schedule.sh. Config-only; the pvesh job mutations
# are live-tested.
#
# The contract:
#   module.backup.schedule > environment.backup.schedule
#                          > site.backup.defaultSchedule > "daily"
#   vocabulary: daily | weekly | monthly | HH:MM (daily at that time)
#   ceiling:    nothing sub-daily — an unsupported spec is REJECTED, never
#               quietly rounded down to daily
#   buckets:    one cluster backup job per distinct frequency; the daily bucket
#               keeps the ORIGINAL marker so an installed site's nightly job is
#               untouched by this change
#
# Usage: ./test-pbs-schedule.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; debug() { :; }; warn() { :; }
ERRORS=""
error() { ERRORS+="$*"$'\n'; }
BOLD=""; CL=""; BL=""; GN=""; BGN=""
get_node_hostname() { echo "tappaas1"; }
CONFIG_DIR="$(mktemp -d)"

# shellcheck source=pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-job.sh"   # sources pbs-schedule.sh and owns PBS_JOB_MARKER

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── the vocabulary, and the ceiling ──────────────────────────────────
ck "bucket: empty → daily"    "daily"   "$(pbs_schedule_bucket '')"
ck "bucket: daily"            "daily"   "$(pbs_schedule_bucket daily)"
ck "bucket: weekly"           "weekly"  "$(pbs_schedule_bucket weekly)"
ck "bucket: monthly"          "monthly" "$(pbs_schedule_bucket monthly)"
ck "bucket: case-insensitive" "weekly"  "$(pbs_schedule_bucket Weekly)"
ck "bucket: HH:MM is daily at that time" "daily" "$(pbs_schedule_bucket '21:00')"
ck "bucket: 00:00 is valid"   "daily"   "$(pbs_schedule_bucket '00:00')"
ck "bucket: 23:59 is valid"   "daily"   "$(pbs_schedule_bucket '23:59')"

# Everything sub-daily — the ceiling §3.2 calls out — must be REFUSED.
for bad in hourly "*:00" "*:0/15" "06,18:00" "mon,thu 06:00" "24:00" "25:00" "9:00" "every 6 hours"; do
    pbs_schedule_bucket "${bad}" >/dev/null && r=0 || r=1
    ck_rc "bucket: '${bad}' refused (ceiling: max once a day)" 1 "$r"
done

# ── start time + calendar event ──────────────────────────────────────
ck "starttime: default"       "21:00" "$(pbs_schedule_starttime daily)"
ck "starttime: explicit HH:MM" "03:30" "$(pbs_schedule_starttime '03:30')"
ck "calendar: daily"          "21:00"         "$(pbs_schedule_calendar daily)"
ck "calendar: daily at a time" "03:30"        "$(pbs_schedule_calendar daily 03:30)"
ck "calendar: weekly"         "sun 21:00"     "$(pbs_schedule_calendar weekly)"
ck "calendar: monthly"        "*-*-01 21:00"  "$(pbs_schedule_calendar monthly)"
pbs_schedule_calendar nonsense >/dev/null && r=0 || r=1
ck_rc "calendar: unknown bucket refused" 1 "$r"

# ── markers: the daily bucket must keep the ORIGINAL marker ──────────
ck "marker: daily is the pre-existing job" "TAPPaaS-backup-vm-managed" "$(pbs_bucket_marker daily)"
ck "marker: weekly"  "TAPPaaS-backup-vm-managed-weekly"  "$(pbs_bucket_marker weekly)"
ck "marker: monthly" "TAPPaaS-backup-vm-managed-monthly" "$(pbs_bucket_marker monthly)"
ck "buckets: all three, frequency order" $'daily\nweekly\nmonthly' "$(pbs_buckets)"

# ── the cascade ──────────────────────────────────────────────────────
mkdir -p "${CONFIG_DIR}/environments"
site()   { printf '%s\n' "$1" > "${CONFIG_DIR}/site.json"; }
env_()   { printf '%s\n' "$2" > "${CONFIG_DIR}/environments/$1.json"; }
module() { printf '%s\n' "$2" > "${CONFIG_DIR}/$1.json"; }

site '{}'
module app '{"environment":"prod"}'
env_ prod '{}'
ck "cascade: nothing set anywhere → daily" "daily" "$(pbs_schedule_resolve app)"

site '{"backup":{"defaultSchedule":"weekly"}}'
ck "cascade: site default applies to a module that says nothing" "weekly" "$(pbs_schedule_resolve app)"

env_ prod '{"backup":{"schedule":"daily"}}'
ck "cascade: environment overrides the site" "daily" "$(pbs_schedule_resolve app)"

module app '{"environment":"prod","backup":{"schedule":"monthly"}}'
ck "cascade: module overrides the environment" "monthly" "$(pbs_schedule_resolve app)"

module app '{"environment":"prod","backup":{"retention":"1y"}}'
ck "cascade: a module with other backup policy but no schedule still inherits" \
   "daily" "$(pbs_schedule_resolve app)"

module orphan '{"backup":{"schedule":"weekly"}}'
ck "cascade: a module with no environment still resolves" "weekly" "$(pbs_schedule_resolve orphan)"

module noenv '{}'
ck "cascade: no environment, no module schedule → the site default" \
   "weekly" "$(pbs_schedule_resolve noenv)"

# ── module → bucket, including the loud failure ──────────────────────
module app '{"environment":"prod","backup":{"schedule":"weekly"}}'
ck "module bucket: resolves through the cascade" "weekly" "$(pbs_module_bucket app)"

ERRORS=""
module bad '{"backup":{"schedule":"hourly"}}'
pbs_module_bucket bad >/dev/null && r=0 || r=1
ck_rc "module bucket: an unsupported schedule FAILS (never silently daily)" 1 "$r"
ck "module bucket: the error names the module and the allowed values" "yes" \
   "$(grep -q "module 'bad'" <<<"${ERRORS}" && grep -q "daily | weekly | monthly" <<<"${ERRORS}" && echo yes || echo no)"

# ── the file-capture window (#691) ───────────────────────────────────
# One renderer decides when a capture runs: the VM job's start, minus a lead,
# plus this module's own deterministic slot.
printf '%s' '{"backup":{"defaultSchedule":"daily"}}' > "${CONFIG_DIR}/site.json"
printf '%s' '{"kind":"vm"}'                          > "${CONFIG_DIR}/alpha.json"
printf '%s' '{"kind":"vm"}'                          > "${CONFIG_DIR}/beta.json"
printf '%s' '{"kind":"vm","backup":{"schedule":"weekly"}}' > "${CONFIG_DIR}/gamma.json"
printf '%s' '{"kind":"vm","backup":{"schedule":"03:30"}}'  > "${CONFIG_DIR}/delta.json"

_w_alpha="$(pbs_fs_window alpha)"
ck "window: before the VM job" "yes" \
   "$([[ "$(_pbs_hm_to_min "${_w_alpha}")" -lt "$(_pbs_hm_to_min "${PBS_DEFAULT_STARTTIME}")" ]] && echo yes || echo no)"
ck "window: inside the lead, with the margin kept" "yes" \
   "$([[ "$(_pbs_hm_to_min "${_w_alpha}")" -ge "$(( $(_pbs_hm_to_min "${PBS_DEFAULT_STARTTIME}") - PBS_FS_LEAD_MINUTES ))" \
      && "$(_pbs_hm_to_min "${_w_alpha}")" -le "$(( $(_pbs_hm_to_min "${PBS_DEFAULT_STARTTIME}") - PBS_FS_MARGIN_MINUTES ))" ]] && echo yes || echo no)"
ck "window: the same module always gets the same slot" "${_w_alpha}" "$(pbs_fs_window alpha)"
ck "window: two modules do not share a slot" "different" \
   "$([[ "${_w_alpha}" != "$(pbs_fs_window beta)" ]] && echo different || echo same)"
ck "window: an explicit HH:MM wins over the derived one" "03:30" "$(pbs_fs_window delta)"

ck "oncalendar: daily is a bare time"    "${_w_alpha}"            "$(pbs_fs_oncalendar alpha)"
ck "oncalendar: weekly keeps its day"    "sun $(pbs_fs_window gamma)" "$(pbs_fs_oncalendar gamma)"

# The invariant is enforced, not hoped for: a spread that would run into the VM
# job fails the render instead of scheduling a collision.
( PBS_FS_SPREAD_MINUTES=50 PBS_FS_MARGIN_MINUTES=15 pbs_fs_window alpha >/dev/null 2>&1 )
ck_rc "window: a spread that cannot fit the lead is refused" 1 $?

# Moving the whole-guest job moves the captures with it — the relationship the
# three hard-coded 20:30s never expressed.
( PBS_DEFAULT_STARTTIME="02:00"
  _early="$(pbs_fs_window alpha)"
  [[ "$(_pbs_hm_to_min "${_early}")" -lt "$(_pbs_hm_to_min "02:00")" ]] ) 
ck_rc "window: follows the VM job when it moves" 0 $?

rm -rf "${CONFIG_DIR}"


echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
