#!/usr/bin/env bash
# test-migration-0024-daily.sh — the fixture test for migration 0024 (#801).
#
# The two old weekly defaults (Tuesday from create-site.sh, Thursday from the
# schema) become daily at 02:00, said with the command that sets weekly back;
# any other schedule, a missing one and other site.json fields are left alone;
# --check writes nothing; a second run is a no-op; the backup holds the
# pre-image; the triple and broken JSON stop it with the file untouched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0024-weekly-default-becomes-daily.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0024.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

site() { rm -rf "${CFG}"; mkdir -p "${CFG}"; printf '{"name":"s","branch":"stable","updateSchedule":%s}\n' "$1" > "${CFG}/site.json"; }
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0024" bash "${M}" "$@" 2>&1; }
sched() { jq -c '.updateSchedule' "${CFG}/site.json"; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

site '{"frequency":"weekly","weekday":"Tuesday","hour":2}'
out="$(run --check)"; rc=$?
ck "--check succeeds"                              0 "${rc}"
ck "--check writes nothing"                        '{"frequency":"weekly","weekday":"Tuesday","hour":2}' "$(sched)"
ck "…and names the change"                         yes "$(has "${out}" "would change updateSchedule")"

out="$(run)"; rc=$?
ck "create-site's default (Tuesday 02:00) → daily" '{"frequency":"daily","hour":2}' "$(sched)"
ck "…the run succeeds"                             0 "${rc}"
ck "…says how to keep weekly"                      yes "$(has "${out}" "--updateFrequency weekly --updateWeekday Tuesday --updateHour 2")"
ck "…other fields are kept"                        '"stable"' "$(jq -c .branch "${CFG}/site.json")"
ck "…the pre-image is backed up"                   '{"frequency":"weekly","weekday":"Tuesday","hour":2}' "$(jq -c .updateSchedule "${CFG}/.migrations/backup/0024/site.json")"
before="$(cat "${CFG}/site.json")"; out="$(run)"
ck "a second run changes nothing"                  "${before}" "$(cat "${CFG}/site.json")"

site '{"frequency":"weekly","weekday":"Thursday","hour":2}'
run >/dev/null
ck "the schema's default (Thursday 02:00) → daily" '{"frequency":"daily","hour":2}' "$(sched)"

for s in '{"frequency":"weekly","weekday":"Sunday","hour":2}' '{"frequency":"weekly","weekday":"Tuesday","hour":4}' \
         '{"frequency":"monthly","weekday":"Tuesday","hour":2}' '{"frequency":"none"}' '{"frequency":"daily","hour":5}'; do
    site "${s}"; out="$(run)"; rc=$?
    ck "a chosen schedule ${s} is left alone" "${s}" "$(sched)"
done
ck "…without a backup"                             no "$([[ -f "${CFG}/.migrations/backup/0024/site.json" ]] && echo yes || echo no)"

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '{"name":"s"}' > "${CFG}/site.json"
out="$(run)"; rc=$?
ck "no updateSchedule (already daily): nothing to do" 0 "${rc}"
ck "…untouched"                                    '{"name":"s"}' "$(jq -c . "${CFG}/site.json")"

site '["weekly","Tuesday",2]'
out="$(run)"; rc=$?
ck "the triple stops it (0003 first)"              1 "${rc}"
ck "…and nothing was written"                      '["weekly","Tuesday",2]' "$(sched)"

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '{"name": ' > "${CFG}/site.json"
out="$(run)"; rc=$?
ck "a site.json that is not JSON stops it"         1 "${rc}"

rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no site.json: nothing to do"                   0 "${rc}"

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
