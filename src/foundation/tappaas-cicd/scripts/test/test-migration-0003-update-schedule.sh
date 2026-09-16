#!/usr/bin/env bash
# test-migration-0003-update-schedule.sh — the fixture test for migration 0003.
#
# The table ADR-025 D12 specifies, case for case: before → after, --check writes
# nothing, applying twice is a no-op, the backup holds the pre-image, and an
# input the migration does not recognise stops it with site.json untouched.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory,
# so it joins the fast tier by existing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0003-update-schedule-object.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
ok() { if [[ -n "$2" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0003.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# A site.json carrying the given updateSchedule, plus fields the migration must
# leave exactly as they are.
site() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    jq -n --argjson s "$1" '{name: "t", email: "a@b.c", automaticReboot: true, updateSchedule: $s, snapshotRetention: 5}' \
        > "${CFG}/site.json"
}
run()   { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0003" bash "${M}" "$@" 2>&1; }
sched() { jq -c '.updateSchedule' "${CFG}/site.json"; }

# ── the four rewrites ───────────────────────────────────────────────────────
site '["daily","Tuesday",2]'
out="$(run)"; rc=$?
ck "daily: the inert weekday is dropped" '{"frequency":"daily","hour":2}' "$(sched)"
ck "…and the run succeeds" 0 "${rc}"
[[ "${out}" == *"Tuesday"* && "${out}" == *"dropped"* ]] \
    && ck "…and the dropped weekday is reported, not discarded in silence" ok ok \
    || ck "…and the dropped weekday is reported, not discarded in silence" ok "got: ${out}"

site '["weekly","Tuesday",2]'
run >/dev/null
ck "weekly keeps its weekday" '{"frequency":"weekly","weekday":"Tuesday","hour":2}' "$(sched)"

site '["monthly","Thursday",2]'
run >/dev/null
ck "monthly keeps its weekday" '{"frequency":"monthly","weekday":"Thursday","hour":2}' "$(sched)"

site '["none","Monday",2]'
out="$(run)"
ck "none drops everything else" '{"frequency":"none"}' "$(sched)"
[[ "${out}" == *"Monday"* ]] && ck "…and says so" ok ok || ck "…and says so" ok missing

# Case and numeric-string spellings some hand-edited sites carry.
site '["WEEKLY","sunday","08"]'
run >/dev/null
ck "case and a numeric string normalize" '{"frequency":"weekly","weekday":"Sunday","hour":8}' "$(sched)"

# ── the rest of site.json is not touched ────────────────────────────────────
site '["weekly","Tuesday",2]'
run >/dev/null
ck "other fields survive" 'a@b.c 5 true' \
   "$(jq -r '[.email, (.snapshotRetention|tostring), (.automaticReboot|tostring)] | join(" ")' "${CFG}/site.json")"

# ── --check writes nothing ──────────────────────────────────────────────────
site '["weekly","Tuesday",2]'
before="$(cat "${CFG}/site.json")"
out="$(run --check)"; rc=$?
ck "--check exits 0" 0 "${rc}"
ck "--check leaves site.json byte-identical" "${before}" "$(cat "${CFG}/site.json")"
[[ "${out}" == *"would rewrite"* ]] && ck "--check says what it would do" ok ok \
                                    || ck "--check says what it would do" ok "got: ${out}"
ck "--check writes no backup" "" "$(ls "${CFG}/.migrations/backup/0003" 2>/dev/null || true)"

# ── the backup holds the pre-image ──────────────────────────────────────────
site '["monthly","Thursday",3]'
before="$(cat "${CFG}/site.json")"
run >/dev/null
ck "the backup is the file as it was" "${before}" "$(cat "${CFG}/.migrations/backup/0003/site.json")"
ck "…and restoring it undoes the migration" '["monthly","Thursday",3]' \
   "$(cp "${CFG}/.migrations/backup/0003/site.json" "${CFG}/site.json" && sched)"

# ── idempotence ─────────────────────────────────────────────────────────────
site '["weekly","Tuesday",2]'
run >/dev/null
after="$(cat "${CFG}/site.json")"
out="$(run)"; rc=$?
ck "a second run exits 0" 0 "${rc}"
ck "…and changes nothing" "${after}" "$(cat "${CFG}/site.json")"
[[ "${out}" == *"already an object"* ]] && ck "…and says it was already migrated" ok ok \
                                        || ck "…and says it was already migrated" ok "got: ${out}"
# The backup from the FIRST run must survive the second untouched: a re-run that
# copied the already-migrated file over it would quietly destroy the only
# pre-image, which is the rollback (ADR-025 D8).
ck "…and leaves the first run's backup as the pre-image" '["weekly","Tuesday",2]' \
   "$(jq -c '.updateSchedule' "${CFG}/.migrations/backup/0003/site.json")"

# ── what it refuses, with site.json untouched in every case ─────────────────
refuses() {  # <label> <updateSchedule JSON>
    site "$2"
    local before; before="$(cat "${CFG}/site.json")"
    run >/dev/null 2>&1 && { ck "refuses ${1}" "non-zero" "0"; return; }
    ck "refuses ${1}" ok ok
    ck "…${1}: site.json is untouched" "${before}" "$(cat "${CFG}/site.json")"
}
refuses "an unknown frequency"        '["fortnightly","Tuesday",2]'
refuses "a weekday that is not a day" '["weekly","Funday",2]'
refuses "an hour outside 0-23"        '["daily",null,24]'
refuses "a non-numeric hour"          '["daily",null,"soon"]'
refuses "a short array"               '["weekly"]'
refuses "weekly with no weekday"      '["weekly",null,2]'
refuses "a string where the triple should be" '"daily"'

# ── nothing to do is not a failure ──────────────────────────────────────────
rm -rf "${CFG}"; mkdir -p "${CFG}"
jq -n '{name: "t"}' > "${CFG}/site.json"
out="$(run)"; rc=$?
ck "no updateSchedule: exits 0" 0 "${rc}"
ck "…and writes nothing" '{"name":"t"}' "$(jq -c . "${CFG}/site.json")"
rm -f "${CFG}/site.json"
run >/dev/null; ck "no site.json at all: exits 0" 0 "$?"

# ── the reader accepts what the migration writes ────────────────────────────
# The point of the whole exercise: after 0003 the renderer must still produce a
# timer, and it must keep reading the legacy triple for a site that has not
# migrated yet (a restored backup, an older release).
# shellcheck source=../../lib/update-schedule.sh
. "${CICD}/lib/update-schedule.sh"
ck "the object form renders"        'Tue *-*-* 02:00:00' "$(update_schedule_oncalendar '{"frequency":"weekly","weekday":"Tuesday","hour":2}' 2>/dev/null)"
ck "daily object renders"           '*-*-* 03:00:00'     "$(update_schedule_oncalendar '{"frequency":"daily","hour":3}' 2>/dev/null)"
ck "monthly object renders"         'Thu *-*-01..07 02:00:00' "$(update_schedule_oncalendar '{"frequency":"monthly","weekday":"Thursday","hour":2}' 2>/dev/null)"
ck "none object: no timer"          ''                   "$(update_schedule_oncalendar '{"frequency":"none"}' 2>/dev/null)"
ck "an object with no hour is 02:00" '*-*-* 02:00:00'    "$(update_schedule_oncalendar '{"frequency":"daily"}' 2>/dev/null)"
ck "the legacy triple still renders" 'Tue *-*-* 02:00:00' "$(update_schedule_oncalendar '["weekly","Tuesday",2]' 2>/dev/null)"
[[ "$(update_schedule_oncalendar '["weekly","Tuesday",2]' 2>&1 >/dev/null)" == *"0003"* ]] \
    && ck "…and names the migration that renames it" ok ok \
    || ck "…and names the migration that renames it" ok missing

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
