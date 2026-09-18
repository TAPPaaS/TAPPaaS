#!/usr/bin/env bash
# test-migration-0006-module-source.sh — the fixture test for migration 0006 (#609).
#
# Before → after for every case the header lists, --check writes nothing,
# applying twice is a no-op, the backup holds the pre-image, a file it cannot
# read or two disagreeing paths stop it before any write, and file modes
# survive. Then the claim the migration rests on: the module is still found
# (get_module_dir, module_of) after the rename, and before it.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0006-location-becomes-module-source.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0006.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0006"
SRC="${TMP}/src/apps/nextcloud"; mkdir -p "${SRC}" "${TMP}/src/foundation/templates"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"vm","location":"'"${SRC}"'","vmid":340,"zone0":"srv"}'              > "${CFG}/nextcloud.json"
    echo '{"location":"'"${TMP}"'/src/foundation/templates","moduleSource":"'"${TMP}"'/src/foundation/templates"}' > "${CFG}/templates.json"
    echo '{"kind":"machine","moduleSource":"/x/debianhost","address":"10.0.0.90"}'     > "${CFG}/dh-test1.json"
    echo '{"name":"site","location":{"country":"DK","timezone":"Europe/Copenhagen"}}' > "${CFG}/site.json"
    echo '["not","an","object"]'                                                       > "${CFG}/list.json"
    echo '{"location":"/old/path"}'                                                    > "${CFG}/nextcloud.json.orig"
    chmod 600 "${CFG}/nextcloud.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
snap() { (cd "${CFG}" && for f in *.json *.orig; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# ── --check writes nothing ──────────────────────────────────────────────────
fixtures; before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would rename"*"nextcloud.json"* ]] && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"
[[ -d "${BK}" ]] && ck "--check makes no backup" none made || ck "--check makes no backup" none none

# ── the rewrites ────────────────────────────────────────────────────────────
fixtures
out="$(run)"; rc=$?
ck "applies"                                   0 "${rc}"
ck "location → moduleSource, in place"         '{"kind":"vm","moduleSource":"'"${SRC}"'","vmid":340,"zone0":"srv"}' "$(jq -c . "${CFG}/nextcloud.json")"
ck "both, the same path → location dropped"    '{"moduleSource":"'"${TMP}"'/src/foundation/templates"}' "$(jq -c . "${CFG}/templates.json")"
ck "already moduleSource → untouched"          '{"kind":"machine","moduleSource":"/x/debianhost","address":"10.0.0.90"}' "$(jq -c . "${CFG}/dh-test1.json")"
ck "a place (site.json location) → untouched"  '{"name":"site","location":{"country":"DK","timezone":"Europe/Copenhagen"}}' "$(jq -c . "${CFG}/site.json")"
ck "a non-object file is untouched"            '["not","an","object"]' "$(jq -c . "${CFG}/list.json")"
ck ".orig is not a config and is untouched"    '{"location":"/old/path"}' "$(jq -c . "${CFG}/nextcloud.json.orig")"
ck "file mode survives"                        600 "$(stat -c %a "${CFG}/nextcloud.json" 2>/dev/null || stat -f %Lp "${CFG}/nextcloud.json")"
ck "backup holds the pre-image"                "${SRC}" "$(jq -r .location "${BK}/nextcloud.json" 2>/dev/null)"
ck "…of every file it changed, and only those" "nextcloud.json templates.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"
ls "${CFG}"/*.0006.tmp >/dev/null 2>&1 && ck "no temp files left" none left || ck "no temp files left" none none

# ── twice is a no-op ────────────────────────────────────────────────────────
before="$(snap)"; out="$(run)"; rc=$?
ck "a second run succeeds"                     0 "${rc}"
ck "…and changes nothing"                      "${before}" "$(snap)"
[[ "${out}" == *"nothing to migrate"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

# ── refuses what it cannot decide, before any write ─────────────────────────
fixtures; echo '{ broken' > "${CFG}/zz-broken.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "an unparseable config stops it"            1 "${rc}"
ck "…before any file is written"               "${before}" "$(snap)"
[[ "${out}" == *"zz-broken.json"* ]] && ck "…and names the file" ok ok || ck "…and names the file" ok "got: ${out}"

fixtures; echo '{"location":"/a/one","moduleSource":"/b/two"}' > "${CFG}/zz-both.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "two different paths stop it"               1 "${rc}"
ck "…before any file is written"               "${before}" "$(snap)"
[[ "${out}" == *"zz-both.json"*"/a/one"*"/b/two"* ]] && ck "…and names both" ok ok || ck "…and names both" ok "got: ${out}"

rm -rf "${CFG}"; mkdir -p "${CFG}"; run >/dev/null; ck "an empty config/ is nothing to do" 0 "$?"

# ── the module is found before and after (get_module_dir, module_of) ───────
find_dir() {   # find_dir → what get_module_dir / module_of answer for nextcloud
    CONFIG_DIR="${CFG}" TAPPAAS_RESOLVE_MODULE_BIN=/nonexistent bash -c '
        . "$1/lib/common-install-routines.sh" >/dev/null 2>&1
        CONFIG_DIR="$2"
        printf "%s %s" "$(get_module_dir nextcloud)" "$(module_of nextcloud)"' _ "${CICD}" "${CFG}" 2>/dev/null
}
fixtures
ck "before: the legacy location still finds it"  "${SRC} nextcloud" "$(find_dir)"
run >/dev/null
ck "after: moduleSource finds it"                "${SRC} nextcloud" "$(find_dir)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
