#!/usr/bin/env bash
# test-migration-0004-kind.sh — the fixture test for migration 0004 (#611).
#
# Before → after for every case the header lists, --check writes nothing,
# applying twice is a no-op, the backup holds the pre-image, a file it cannot
# read stops it before any write, and file modes survive. Then the claim the
# migration exists for, against the REAL 3-way merge: once the marker is gone,
# the next update adopts the kind the module authors — and without the
# migration it never would.
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"
M="${CICD}/migrations/0004-kind-names-the-workload.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0004.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0004"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"module","location":"/src/apps/nextcloud","vmid":340,"zone0":"srv"}'  > "${CFG}/nextcloud.json"
    echo '{"kind":"module","dependsOn":["cluster:vm"],"vmid":130}'                     > "${CFG}/tappaas-cicd.json"
    echo '{"name":"scratch","kind":"module","vmid":"202","backup":{"enabled":false}}'  > "${CFG}/scratch.json"
    echo '{"kind":"external-host","status":"external","host":{"sshUser":"root"}}'      > "${CFG}/satellite-satellite1.json"
    echo '{"kind":"vm","location":"/src/apps/openwebui"}'                              > "${CFG}/openwebui.json"
    echo '{"location":"/src/foundation/templates"}'                                    > "${CFG}/templates.json"
    echo '{"name":"site","updateSchedule":{"frequency":"daily","hour":2}}'             > "${CFG}/site.json"
    echo '["not","an","object"]'                                                       > "${CFG}/list.json"
    chmod 600 "${CFG}/nextcloud.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
kind() { jq -r 'if has("kind") then .kind else "(none)" end' "${CFG}/$1.json"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# ── --check writes nothing ──────────────────────────────────────────────────
fixtures; before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would remove"*"nextcloud.json"* && "${out}" == *"external-host"*"machine"* ]] \
    && ck "--check says what it would do" ok ok || ck "--check says what it would do" ok "got: ${out}"
[[ -d "${BK}" ]] && ck "--check makes no backup" none made || ck "--check makes no backup" none none

# ── the rewrites ────────────────────────────────────────────────────────────
fixtures
out="$(run)"; rc=$?
ck "applies"                                        0 "${rc}"
ck "marker + location → removed"                    "(none)"  "$(kind nextcloud)"
ck "marker + dependsOn → removed"                   "(none)"  "$(kind tappaas-cicd)"
ck "marker as ONLY signal → kept"                   "module"  "$(kind scratch)"
[[ "${out}" == *"scratch.json"*"KEPT"* ]] && ck "…and named in the output" ok ok || ck "…and named in the output" ok "got: ${out}"
ck "external-host → machine"                        "machine" "$(kind satellite-satellite1)"
ck "an authored kind is left alone"                 "vm"      "$(kind openwebui)"
ck "no kind stays no kind"                          "(none)"  "$(kind templates)"
ck "other fields untouched"                         '{"location":"/src/apps/nextcloud","vmid":340,"zone0":"srv"}' "$(jq -c . "${CFG}/nextcloud.json")"
ck "site.json untouched"                            '{"name":"site","updateSchedule":{"frequency":"daily","hour":2}}' "$(jq -c . "${CFG}/site.json")"
ck "a non-object file is untouched"                 '["not","an","object"]' "$(jq -c . "${CFG}/list.json")"
ck "file mode survives"                             600 "$(stat -c %a "${CFG}/nextcloud.json" 2>/dev/null || stat -f %Lp "${CFG}/nextcloud.json")"
ck "backup holds the pre-image"                     module "$(jq -r .kind "${BK}/nextcloud.json" 2>/dev/null)"
ck "…of every file it changed, and only those"      "nextcloud.json satellite-satellite1.json tappaas-cicd.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"
ls "${CFG}"/*.0004.tmp >/dev/null 2>&1 && ck "no temp files left" none left || ck "no temp files left" none none

# ── twice is a no-op ────────────────────────────────────────────────────────
before="$(snap)"; out="$(run)"; rc=$?
ck "a second run succeeds"                     0 "${rc}"
ck "…and changes nothing"                      "${before}" "$(snap)"
[[ "${out}" == *"nothing to migrate"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

# ── refuses what it cannot read, before any write ───────────────────────────
fixtures; echo '{ broken' > "${CFG}/zz-broken.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "an unparseable config stops it"            1 "${rc}"
ck "…before any file is written"               "${before}" "$(snap)"
[[ "${out}" == *"zz-broken.json"* ]] && ck "…and names the file" ok ok || ck "…and names the file" ok "got: ${out}"

# ── empty config dir ────────────────────────────────────────────────────────
rm -rf "${CFG}"; mkdir -p "${CFG}"; run >/dev/null; ck "an empty config/ is nothing to do" 0 "$?"

# ── the chain it exists for, against the REAL 3-way merge ───────────────────
# deployed: the stamped marker; .orig: the release before #611 (no kind);
# release: now authors kind "vm". Needs the composed schema and the converter.
if SCHEMA="$(mktemp)" && "${CICD}/scripts/compose-fields.sh" "${FOUNDATION}" > "${SCHEMA}" 2>/dev/null \
   && [[ -f "${CICD}/manager/site-manager/convert-json-to-config.sh" ]]; then
    merge_kind() {   # merge_kind <migrate: yes|no> → the kind after the merge
        local cd="${TMP}/m-$1/config" md="${TMP}/m-$1/src/demo"
        rm -rf "${TMP}/m-$1"; mkdir -p "${cd}" "${md}"
        echo '{"kind":"module","location":"'"${md}"'","dependsOn":["cluster:vm"],"cores":2}' > "${cd}/demo.json"
        echo '{"dependsOn":["cluster:vm"],"cores":2}'                                     > "${cd}/demo.json.orig"
        echo '{"kind":"vm","dependsOn":["cluster:vm"],"cores":2}'                           > "${md}/demo.json"
        [[ "$1" == yes ]] && CONFIG_DIR="${cd}" TAPPAAS_MIGRATION_BACKUP_DIR="${cd}/bk" bash "${M}" >/dev/null 2>&1
        local out
        out="$(TAPPAAS_MERGE_CONFIG_DIR="${cd}" TAPPAAS_SCHEMA_FILE="${SCHEMA}" bash -c '
            . "$1/tappaas-cicd/lib/common-install-routines.sh" >/dev/null 2>&1
            . "$1/tappaas-cicd/lib/apply-json-merge.sh"
            apply_three_way_merge demo "$2"' _ "${FOUNDATION}" "${md}" 2>&1)" || {
            # The merge library finds its converter only where a mothership keeps it.
            [[ "${out}" == *"convert-json-to-config.sh not found"* ]] && echo "no-converter" || echo "merge-failed"
            return; }
        jq -r '[.. | objects | select(has("kind")) | .kind][0] // "(none)"' "${cd}/demo.json"
    }
    without="$(merge_kind no)"; with="$(merge_kind yes)"
    if [[ "${without}" == no-converter ]]; then
        echo "  - merge chain: the merge library's converter is not installed here (mothership only) — skipped"
    else
        ck "without 0004 the merge keeps the marker (rule 5)"  module "${without}"
        ck "with 0004 the merge adopts the authored kind"      vm     "${with}"
    fi
    rm -f "${SCHEMA}"
else
    echo "  - merge chain: composed schema or converter unavailable here — skipped"
fi

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
