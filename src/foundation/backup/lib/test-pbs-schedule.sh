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

rm -rf "${CONFIG_DIR}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
