#!/usr/bin/env bash
# test-migration-0008-satellite-source.sh — the fixture test for migration 0008.
#
# Before → after, --check writes nothing, twice is a no-op, the backup holds the
# pre-image, the refusals stop it before any write, file modes survive — and the
# claim it exists for: after it, get_module_dir / module_of name the satellite's
# module, where before they could not.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0008-satellite-records-its-module.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0008.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0008"
REPO="${TMP}/repo/src/foundation"; mkdir -p "${REPO}/tappaas-cicd" "${REPO}/satellite"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"vm","moduleSource":"'"${REPO}"'/tappaas-cicd","vmid":130}'                 > "${CFG}/tappaas-cicd.json"
    echo '{"kind":"machine","status":"external","name":"satellite1","host":{"publicIp":"1.2.3.4"}}' > "${CFG}/satellite-satellite1.json"
    echo '{"kind":"machine","name":"s2","physicalLocation":{"country":"FI"},"location":""}'   > "${CFG}/satellite-s2.json"
    echo '{"kind":"machine","name":"s3","moduleSource":"/elsewhere/satellite"}'               > "${CFG}/satellite-s3.json"
    echo '{"kind":"machine","name":"s4","location":{"country":"DE"}}'                          > "${CFG}/satellite-s4.json"
    echo '{"kind":"machine","address":"10.0.0.90","moduleSource":"/x/debianhost"}'             > "${CFG}/dh-test1.json"
    chmod 600 "${CFG}/satellite-satellite1.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
src()  { jq -r '.moduleSource // "(none)"' "${CFG}/$1.json"; }
modof() {
    CONFIG_DIR="${CFG}" TAPPAAS_RESOLVE_MODULE_BIN=/nonexistent bash -c '
        . "$1/lib/common-install-routines.sh" >/dev/null 2>&1
        CONFIG_DIR="$2"; module_of "$3" 2>/dev/null || echo "(none)"' _ "${CICD}" "${CFG}" "$1"
}

fixtures; before="$(snap)"
ck "before: nothing names the satellite's module" "(none)" "$(modof satellite-satellite1)"
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would record"*"satellite-satellite1.json"* ]] && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"

out="$(run)"; rc=$?
ck "applies"                                   0 "${rc}"
ck "moduleSource recorded, beside tappaas-cicd" "${REPO}/satellite" "$(src satellite-satellite1)"
ck "…the rest of the config untouched"         '{"kind":"machine","status":"external","name":"satellite1","host":{"publicIp":"1.2.3.4"}}' "$(jq -c 'del(.moduleSource)' "${CFG}/satellite-satellite1.json")"
ck "an empty location is dropped, a place kept" '{"kind":"machine","name":"s2","physicalLocation":{"country":"FI"},"moduleSource":"'"${REPO}"'/satellite"}' "$(jq -c . "${CFG}/satellite-s2.json")"
ck "an existing moduleSource is left alone"   "/elsewhere/satellite" "$(src satellite-s3)"
ck "a place-shaped location survives"          '{"country":"DE"}' "$(jq -c .location "${CFG}/satellite-s4.json")"
ck "not a satellite → untouched"               "/x/debianhost" "$(src dh-test1)"
ck "after: module_of names the satellite module" satellite "$(modof satellite-satellite1)"
ck "file mode survives"                        600 "$(stat -c %a "${CFG}/satellite-satellite1.json" 2>/dev/null || stat -f %Lp "${CFG}/satellite-satellite1.json")"
ck "backup holds the pre-images, only those"   "satellite-s2.json satellite-s4.json satellite-satellite1.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"

before="$(snap)"; out="$(run)"; rc=$?
ck "a second run succeeds"                     0 "${rc}"
ck "…and changes nothing"                      "${before}" "$(snap)"

fixtures; rm -rf "${REPO}/satellite"; before="$(snap)"
out="$(run)"; rc=$?
ck "no satellite module beside tappaas-cicd → refused" 1 "${rc}"
ck "…before any write"                         "${before}" "$(snap)"
mkdir -p "${REPO}/satellite"

fixtures; echo '{"kind":"vm","vmid":130}' > "${CFG}/tappaas-cicd.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "tappaas-cicd records no source → refused"  1 "${rc}"
ck "…before any write"                         "${before}" "$(snap)"

fixtures; echo '{ broken' > "${CFG}/satellite-zz.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "an unparseable satellite config stops it"  1 "${rc}"
ck "…before any write"                         "${before}" "$(snap)"

rm -rf "${CFG}"; mkdir -p "${CFG}"; run >/dev/null; ck "no satellite at all is nothing to do" 0 "$?"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
