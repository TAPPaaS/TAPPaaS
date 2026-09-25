#!/usr/bin/env bash
# test-migration-0011-site-backup.sh — the fixture test for migration 0011 (#737).
#
# before → after, --check writes nothing, applying twice is a no-op, the backup
# holds the pre-image, and a shape the migration does not recognise stops it with
# site.json untouched. Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0011-site-backup-is-an-object.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0011.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# A site.json carrying the given backup value, plus fields the migration must
# leave exactly as they are.
site() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    jq -n --argjson b "$1" '{name: "t", automaticReboot: true, backup: $b, snapshotRetention: 5}' > "${CFG}/site.json"
}
run()    { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0011" bash "${M}" "$@" 2>&1; }
backup() { jq -c '.backup' "${CFG}/site.json"; }
rest()   { jq -c 'del(.backup)' "${CFG}/site.json"; }

site 'true'
out="$(run)"; rc=$?
ck "true → {}"                                  '{}' "$(backup)"
ck "…the run succeeds"                          0 "${rc}"
ck "…and the missing target is reported"        yes "$([[ "${out}" == *"no backup target is recorded"* ]] && echo yes || echo no)"
ck "…other fields untouched"                    '{"name":"t","automaticReboot":true,"snapshotRetention":5}' "$(rest)"
ck "…the pre-image is backed up"                'true' "$(jq -c .backup "${CFG}/.migrations/backup/0011/site.json")"
before="$(cat "${CFG}/site.json")"; run >/dev/null
ck "a second run changes nothing"               "${before}" "$(cat "${CFG}/site.json")"

site 'false'
run >/dev/null
ck "false → null"                               'null' "$(backup)"

site 'true'
out="$(run --check)"
ck "--check writes nothing"                     'true' "$(backup)"
ck "…and says what it would do"                 yes "$([[ "${out}" == *"would rewrite backup true → {}"* ]] && echo yes || echo no)"

site '{"target":"backup.mgmt.internal","defaultSchedule":"daily"}'
run >/dev/null
ck "an object is left alone"                    '{"target":"backup.mgmt.internal","defaultSchedule":"daily"}' "$(backup)"
site 'null'; run >/dev/null
ck "null is left alone"                         'null' "$(backup)"
rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '{"name":"t"}' > "${CFG}/site.json"; run >/dev/null
ck "no backup key: left alone"                  '{"name":"t"}' "$(jq -c . "${CFG}/site.json")"

site '"yes"'
run >/dev/null; rc=$?
ck "a string: refused (rc 1)"                   1 "${rc}"
ck "…and site.json untouched"                   '"yes"' "$(backup)"

echo ""
echo "test-migration-0011: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
