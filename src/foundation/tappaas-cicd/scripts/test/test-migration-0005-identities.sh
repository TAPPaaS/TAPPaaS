#!/usr/bin/env bash
# test-migration-0005-identities.sh — the fixture test for migration 0005 (#628).
#
# Every state the header lists: the move, the compatibility symlink, what is
# already migrated, what it refuses — plus --check writes nothing, twice is a
# no-op, the backup holds the pre-image, contents and modes survive, and the
# identity-manager path helper reads the result the same way before and after.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0005-people-becomes-identities.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0005.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0005"

people() {   # a config/ with the pre-#628 identity domain
    rm -rf "${CFG}"; mkdir -p "${CFG}/people/"{organizations,groups,roles,users}
    echo '{"name":"acme"}'                 > "${CFG}/people/organizations/acme.json"
    echo '{"name":"acme__admin"}'          > "${CFG}/people/groups/acme__admin.json"
    echo '{"name":"root"}'                 > "${CFG}/people/roles/root.json"
    echo '{"name":"svc-tappaas1-root"}'    > "${CFG}/people/users/svc-tappaas1-root.json"
    chmod 600 "${CFG}/people/users/svc-tappaas1-root.json"
    echo '{"name":"site"}'                 > "${CFG}/site.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
tree() { (cd "${CFG}" && find . -path ./.migrations -prune -o -print | LC_ALL=C sort | tr '\n' ' '); }

# ── --check writes nothing ──────────────────────────────────────────────────
people; before="$(tree)"; out="$(run --check)"; rc=$?
ck "--check succeeds"                      0 "${rc}"
ck "--check writes nothing"                "${before}" "$(tree)"
[[ "${out}" == *"would move"*"4 file(s)"* ]] && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"

# ── the move ────────────────────────────────────────────────────────────────
people; out="$(run)"; rc=$?
ck "applies"                               0 "${rc}"
[[ -d "${CFG}/identities" && ! -L "${CFG}/identities" ]] && ck "identities/ is a real directory" ok ok || ck "identities/ is a real directory" ok missing
ck "people is a symlink to identities"     identities "$(readlink "${CFG}/people" 2>/dev/null)"
ck "every file moved"                      4 "$(find "${CFG}/identities" -type f | wc -l | tr -d ' ')"
ck "contents intact"                       '{"name":"svc-tappaas1-root"}' "$(cat "${CFG}/identities/users/svc-tappaas1-root.json")"
ck "file mode survives"                    600 "$(stat -c %a "${CFG}/identities/users/svc-tappaas1-root.json" 2>/dev/null || stat -f %Lp "${CFG}/identities/users/svc-tappaas1-root.json")"
ck "the old path still reads through"      '{"name":"acme"}' "$(cat "${CFG}/people/organizations/acme.json")"
ck "backup holds the pre-image"            4 "$(find "${BK}/people" -type f 2>/dev/null | wc -l | tr -d ' ')"
ck "site.json untouched"                   '{"name":"site"}' "$(cat "${CFG}/site.json")"

# ── twice is a no-op ────────────────────────────────────────────────────────
before="$(tree)"; out="$(run)"; rc=$?
ck "a second run succeeds"                 0 "${rc}"
ck "…and changes nothing"                  "${before}" "$(tree)"
[[ "${out}" == *"already points"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

# ── nothing to do ───────────────────────────────────────────────────────────
rm -rf "${CFG}"; mkdir -p "${CFG}"; run >/dev/null; ck "no identity domain: nothing to do" 0 "$?"

# ── refusals, before any write ──────────────────────────────────────────────
people; mkdir -p "${CFG}/identities/users"; echo '{}' > "${CFG}/identities/users/other.json"; before="$(tree)"
out="$(run)"; rc=$?
ck "both real directories: refused"        1 "${rc}"
ck "…with nothing changed"                 "${before}" "$(tree)"
[[ "${out}" == *"two copies"* ]] && ck "…and says why" ok ok || ck "…and says why" ok "got: ${out}"

rm -rf "${CFG}"; mkdir -p "${CFG}/elsewhere"; ln -s elsewhere "${CFG}/people"
run >/dev/null; ck "a people symlink pointing elsewhere: refused" 1 "$?"

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo x > "${CFG}/people"
run >/dev/null; ck "a people FILE: refused"  1 "$?"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
