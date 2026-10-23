#!/usr/bin/env bash
# test-migration-0017-site-organizations.sh — the fixture test for migration 0017 (#867).
#
# before → after, --check writes nothing, applying twice is a no-op, the backup
# holds the pre-image, the organization files are not touched, and a site.json
# that is not an object stops it untouched. Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0017-site-organizations-removed.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0017.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# A site.json with the given organizations value (or none), plus fields the
# migration must leave exactly as they are, and one organization file.
site() {
    rm -rf "${CFG}"; mkdir -p "${CFG}/identities/organizations"
    echo '{"name":"acme"}' > "${CFG}/identities/organizations/acme.json"
    if [[ $# -eq 0 ]]; then
        jq -n '{name: "t", owner: "acme", snapshotRetention: 5}' > "${CFG}/site.json"
    else
        jq -n --argjson o "$1" '{name: "t", owner: "acme", organizations: $o, snapshotRetention: 5}' > "${CFG}/site.json"
    fi
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0017" bash "${M}" "$@" 2>&1; }
has() { jq -r 'has("organizations")' "${CFG}/site.json"; }

site '["config/people/organizations/acme.json"]'
out="$(run)"; rc=$?
ck "organizations removed"                      false "$(has)"
ck "…the run succeeds"                          0 "${rc}"
ck "…and what it listed is reported"            yes "$([[ "${out}" == *'organizations ["config/people/organizations/acme.json"] removed'* ]] && echo yes || echo no)"
ck "…other fields untouched"                    '{"name":"t","owner":"acme","snapshotRetention":5}' "$(jq -c . "${CFG}/site.json")"
ck "…the pre-image is backed up"                '["config/people/organizations/acme.json"]' "$(jq -c .organizations "${CFG}/.migrations/backup/0017/site.json")"
ck "…the organization file is kept"             '{"name":"acme"}' "$(cat "${CFG}/identities/organizations/acme.json")"
before="$(cat "${CFG}/site.json")"; out="$(run)"
ck "a second run changes nothing"               "${before}" "$(cat "${CFG}/site.json")"
ck "…and says so"                               yes "$([[ "${out}" == *"nothing to migrate"* ]] && echo yes || echo no)"

site '[]'
run >/dev/null
ck "an empty list is removed too"               false "$(has)"

site 'null'
run >/dev/null
ck "a null value is removed too"                false "$(has)"

site '["config/identities/organizations/acme.json"]'
out="$(run --check)"
ck "--check writes nothing"                     true "$(has)"
ck "…no backup is made"                         no "$([[ -e "${CFG}/.migrations/backup/0017" ]] && echo yes || echo no)"
ck "…and says what it would do"                 yes "$([[ "${out}" == *"would remove organizations"* ]] && echo yes || echo no)"

site
run >/dev/null; rc=$?
ck "no organizations key: left alone"           '{"name":"t","owner":"acme","snapshotRetention":5}' "$(jq -c . "${CFG}/site.json")"
ck "…exit 0"                                    0 "${rc}"

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '["x"]' > "${CFG}/site.json"
run >/dev/null; rc=$?
ck "a site.json that is no object: refused (rc 1)" 1 "${rc}"
ck "…and untouched"                             '["x"]' "$(jq -c . "${CFG}/site.json")"

rm -rf "${CFG}"; mkdir -p "${CFG}"
run >/dev/null; rc=$?
ck "no site.json: nothing to do (rc 0)"         0 "${rc}"

echo ""
echo "test-migration-0017: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
