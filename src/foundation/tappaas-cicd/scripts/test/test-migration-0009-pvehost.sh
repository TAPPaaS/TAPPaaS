#!/usr/bin/env bash
# test-migration-0009-pvehost.sh — the fixture test for migration 0009.
#
# Before → after, --check writes nothing, twice is a no-op, the backup holds the
# pre-images and only those, a missing target stops it before any write, file
# modes survive — and the claim it exists for: after it, module_of names the
# nodes' module pvehost.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0009-pvenode-becomes-pvehost.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0009.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0009"
REPO="${TMP}/repo/src/foundation"; mkdir -p "${REPO}/pvehost" "${REPO}/debianhost"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"machine","moduleSource":"'"${REPO}"'/pvenode","address":"tappaas1.mgmt.internal","tier":"foundation"}' > "${CFG}/tappaas1.json"
    echo '{"kind":"machine","moduleSource":"'"${REPO}"'/pvenode","address":"tappaas2.mgmt.internal"}'                     > "${CFG}/tappaas2.json"
    echo '{"kind":"machine","moduleSource":"'"${REPO}"'/debianhost","address":"10.0.0.90"}'                              > "${CFG}/dh-test1.json"
    echo '{"kind":"vm","moduleSource":"'"${REPO}"'/tappaas-cicd","vmid":130}'                                             > "${CFG}/tappaas-cicd.json"
    echo '{"name":"site"}'                                                                                                 > "${CFG}/site.json"
    chmod 600 "${CFG}/tappaas1.json"
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
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would point tappaas1.json"* ]] && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"

out="$(run)"; rc=$?
ck "applies"                                   0 "${rc}"
ck "tappaas1 names pvehost"                    "${REPO}/pvehost" "$(src tappaas1)"
ck "tappaas2 names pvehost"                    "${REPO}/pvehost" "$(src tappaas2)"
ck "…the rest of the config untouched"         '{"kind":"machine","address":"tappaas1.mgmt.internal","tier":"foundation"}' "$(jq -c 'del(.moduleSource)' "${CFG}/tappaas1.json")"
ck "a debianhost is untouched"                 "${REPO}/debianhost" "$(src dh-test1)"
ck "after: module_of names pvehost"            pvehost "$(modof tappaas1)"
ck "file mode survives"                        600 "$(stat -c %a "${CFG}/tappaas1.json" 2>/dev/null || stat -f %Lp "${CFG}/tappaas1.json")"
ck "backup holds the pre-images, only those"   "tappaas1.json tappaas2.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"
ck "backup is the pre-image"                   "${REPO}/pvenode" "$(jq -r .moduleSource "${BK}/tappaas1.json")"

after="$(snap)"
out="$(run)"; rc=$?
ck "twice is a no-op"                          "${after}" "$(snap)"
[[ "${out}" == *"nothing to migrate"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

# The refusals stop it before any write.
fixtures; rmdir "${REPO}/pvehost"; before="$(snap)"
out="$(run)"; rc=$?
ck "no pvehost module → refuses"               1 "${rc}"
ck "…and writes nothing"                       "${before}" "$(snap)"
mkdir -p "${REPO}/pvehost"

fixtures; echo '{ not json' > "${CFG}/broken.json"; before="$(snap 2>/dev/null)"
out="$(run)"; rc=$?
ck "invalid JSON → refuses"                    1 "${rc}"
ck "…and writes nothing"                       "${before}" "$(snap 2>/dev/null)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
