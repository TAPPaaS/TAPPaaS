#!/usr/bin/env bash
# test-migration-0010-backup-policy.sh — the fixture test for migration 0010.
#
# Before → after, --check writes nothing, twice is a no-op, the backup holds the
# pre-images and only those, file modes survive, a bad JSON stops it before any
# write — and the claim it exists for: only a config the converter would warn
# about loses its `backup`. The live shapes of 2026-09-19 (hrossen) are the
# fixtures: a machine instance, the backup module itself, a VM that
# integratesWith backup, and site.json.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0010-backup-policy-needs-a-backup-service.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0010.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0010"
POLICY='{"enabled":true,"exclude":[],"retention":"7y"}'

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    # A cluster node: a machine instance that wires no backup service (#672 follow-up).
    echo '{"kind":"machine","moduleSource":"/x/pvehost","dependsOn":[],"backup":'"${POLICY}"'}'        > "${CFG}/tappaas1.json"
    # The backup module itself: it PROVIDES the services, and reads its own policy.
    echo '{"kind":"application","moduleSource":"/x/backup","provides":["vm","filesystem"],"backup":'"${POLICY}"'}' > "${CFG}/backup.json"
    # A VM that integratesWith backup — keeps its filesystemPaths.
    echo '{"kind":"vm","moduleSource":"/x/cicd","dependsOn":["cluster:vm"],"integratesWith":["backup:vm","backup:filesystem"],"backup":{"filesystemPaths":["/etc/secrets"]}}' > "${CFG}/tappaas-cicd.json"
    # A VM that depends on backup:vm.
    echo '{"kind":"vm","moduleSource":"/x/nextcloud","dependsOn":["backup:vm"],"backup":'"${POLICY}"'}' > "${CFG}/nextcloud.json"
    # Not a module: site.json carries the site-wide target + schedule.
    # …and its `location` is a physical PLACE (an object), not a module path.
    echo '{"name":"site","location":{"country":"DK"},"backup":{"target":"backup.mgmt.internal","defaultSchedule":"daily"}}' > "${CFG}/site.json"
    # A module with no backup policy at all.
    echo '{"kind":"vm","moduleSource":"/x/litellm","dependsOn":["cluster:vm"]}'                          > "${CFG}/litellm.json"
    chmod 600 "${CFG}/tappaas1.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
has()  { jq -e 'has("backup")' "${CFG}/$1.json" >/dev/null 2>&1 && echo yes || echo no; }

fixtures; before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would remove the backup policy from tappaas1.json"* ]] && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"

out="$(run)"; rc=$?
ck "applies"                                   0 "${rc}"
ck "a machine loses the policy it cannot use"  no  "$(has tappaas1)"
ck "…and the rest of its config survives"      '{"kind":"machine","moduleSource":"/x/pvehost","dependsOn":[]}' "$(jq -c . "${CFG}/tappaas1.json")"
ck "the backup module keeps its own policy"    yes "$(has backup)"
ck "an integratesWith consumer keeps its paths" '["/etc/secrets"]' "$(jq -c '.backup.filesystemPaths' "${CFG}/tappaas-cicd.json")"
ck "a dependsOn consumer keeps its policy"     yes "$(has nextcloud)"
ck "site.json is not a module — untouched"     yes "$(has site)"
ck "file mode survives"                        600 "$(stat -c %a "${CFG}/tappaas1.json" 2>/dev/null || stat -f %Lp "${CFG}/tappaas1.json")"
ck "backup holds the pre-images, only those"   "tappaas1.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"
ck "backup is the pre-image"                   "${POLICY}" "$(jq -c .backup "${BK}/tappaas1.json")"

after="$(snap)"
out="$(run)"; rc=$?
ck "twice is a no-op"                          "${after}" "$(snap)"
[[ "${out}" == *"nothing to migrate"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

fixtures; echo '{ not json' > "${CFG}/broken.json"; before="$(snap 2>/dev/null)"
out="$(run)"; rc=$?
ck "invalid JSON → refuses"                    1 "${rc}"
ck "…and writes nothing"                       "${before}" "$(snap 2>/dev/null)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
