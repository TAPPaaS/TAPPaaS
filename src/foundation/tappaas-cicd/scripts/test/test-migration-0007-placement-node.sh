#!/usr/bin/env bash
# test-migration-0007-placement-node.sh — the fixture test for migration 0007 (#600).
#
# Before → after, --check writes nothing, twice is a no-op, the backup holds the
# pre-image, refusals stop it before any write, file modes survive — and the
# claim it rests on: the backup module finds the same Host before and after
# (pbs_placement_state / pbs_state_node read both shapes).
#
# Every migration ships one of these (ADR-025 D7); Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"
M="${CICD}/migrations/0007-placement-node-names-the-host.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0007.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; BK="${CFG}/.migrations/backup/0007"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"application","placementState":"node:tappaas3","node":"","storage":"tankc1"}'  > "${CFG}/backup.json"
    echo '{"placementState":"node:dh-test1","node":"tappaas2"}'                                   > "${CFG}/pbs2.json"
    echo '{"placementState":"node","node":"tappaas1"}'                                            > "${CFG}/pbs3.json"
    echo '{"placementState":"shim","node":"tappaas2"}'                                            > "${CFG}/pbs4.json"
    echo '{"placementState":"external","pbsUrl":"pbs.lan"}'                                       > "${CFG}/pbs5.json"
    echo '{"name":"site"}'                                                                        > "${CFG}/site.json"
    chmod 600 "${CFG}/backup.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
host() {  # host <file> → the Host the backup module reads from it
    bash -c '
        info() { :; }; warn() { :; }; debug() { :; }
        PBS_PLACEMENT_CONFIG_DIR="$2"
        . "$1/backup/lib/pbs-placement.sh"
        pbs_state_node "$(pbs_placement_state "$3")" || echo "(none)"' _ "${FOUNDATION}" "${CFG}" "${CFG}/$1.json"
}

fixtures; before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check succeeds"                          0 "${rc}"
ck "--check writes nothing"                    "${before}" "$(snap)"
[[ "${out}" == *"would rewrite"*"pbs2.json"*"replaces the constraint \"tappaas2\""* ]] && ck "--check names a replaced constraint" ok ok || ck "--check names a replaced constraint" ok "got: ${out}"

fixtures
ck "before: the module reads tappaas3"         tappaas3 "$(host backup)"
ck "before: …and dh-test1"                     dh-test1 "$(host pbs2)"
out="$(run)"; rc=$?
ck "applies"                                   0 "${rc}"
ck "node:<host> → node + .node"                '{"kind":"application","placementState":"node","node":"tappaas3","storage":"tankc1"}' "$(jq -c . "${CFG}/backup.json")"
ck "a constraint is replaced by the Host"      '{"placementState":"node","node":"dh-test1"}' "$(jq -c . "${CFG}/pbs2.json")"
[[ "${out}" == *"pbs2.json"*"replaces the constraint"* ]] && ck "…and it is reported" ok ok || ck "…and it is reported" ok "got: ${out}"
ck "already node + .node → untouched"          '{"placementState":"node","node":"tappaas1"}' "$(jq -c . "${CFG}/pbs3.json")"
ck "shim keeps its constraint"                 '{"placementState":"shim","node":"tappaas2"}' "$(jq -c . "${CFG}/pbs4.json")"
ck "external untouched"                        '{"placementState":"external","pbsUrl":"pbs.lan"}' "$(jq -c . "${CFG}/pbs5.json")"
ck "after: the module still reads tappaas3"    tappaas3 "$(host backup)"
ck "after: …and dh-test1"                      dh-test1 "$(host pbs2)"
ck "file mode survives"                        600 "$(stat -c %a "${CFG}/backup.json" 2>/dev/null || stat -f %Lp "${CFG}/backup.json")"
ck "backup holds the pre-images, only those"   "backup.json pbs2.json" "$(cd "${BK}" && ls | tr '\n' ' ' | sed 's/ $//')"
ck "…the old shape"                            node:tappaas3 "$(jq -r .placementState "${BK}/backup.json")"

before="$(snap)"; out="$(run)"; rc=$?
ck "a second run succeeds"                     0 "${rc}"
ck "…and changes nothing"                      "${before}" "$(snap)"
[[ "${out}" == *"nothing to migrate"* ]] && ck "…and says so" ok ok || ck "…and says so" ok "got: ${out}"

fixtures; echo '{ broken' > "${CFG}/zz.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "an unparseable config stops it"            1 "${rc}"
ck "…before any write"                         "${before}" "$(snap)"
fixtures; echo '{"placementState":"node:"}' > "${CFG}/zz.json"; before="$(snap)"
out="$(run)"; rc=$?
ck "node: naming no Host stops it"             1 "${rc}"
ck "…before any write"                         "${before}" "$(snap)"

echo '{"placementState":"node","node":""}' > "${CFG}/half.json"
ck "node with no .node reads as unresolved"    "(none)" "$(host half)"

# ── the real 3-way merge keeps the Host in .node ────────────────────────────
# backup/DESIGN.md used to say the merge "may legitimately reset" .node. It must
# not: after 0007 the Host lives there. Deployed: node + Host; .orig and the
# release both ship node "" and placementState "". Mothership only (converter).
if SCHEMA="$(mktemp)" && "${CICD}/scripts/compose-fields.sh" "${FOUNDATION}" > "${SCHEMA}" 2>/dev/null \
   && [[ -f "${CICD}/manager/site-manager/convert-json-to-config.sh" ]]; then
    cd_="${TMP}/merge/config"; md="${TMP}/merge/src/backup"; mkdir -p "${cd_}" "${md}"
    echo '{"kind":"application","moduleSource":"'"${md}"'","placementState":"node","node":"tappaas3","storage":"tankc1","pbsUrl":"backup.mgmt.internal"}' > "${cd_}/backup.json"
    echo '{"kind":"application","placementState":"","node":"","storage":"tankc1","pbsUrl":"backup.mgmt.internal"}' > "${cd_}/backup.json.orig"
    echo '{"kind":"application","placementState":"","node":"","storage":"tankc1","pbsUrl":"backup.mgmt.internal","newField":1}' > "${md}/backup.json"
    mout="$(TAPPAAS_MERGE_CONFIG_DIR="${cd_}" TAPPAAS_SCHEMA_FILE="${SCHEMA}" bash -c '
        . "$1/tappaas-cicd/lib/common-install-routines.sh" >/dev/null 2>&1
        . "$1/tappaas-cicd/lib/apply-json-merge.sh"
        apply_three_way_merge backup "$2"' _ "${FOUNDATION}" "${md}" 2>&1)"; mrc=$?
    if [[ "${mout}" == *"convert-json-to-config.sh not found"* ]]; then
        echo "  - merge chain: the merge library's converter is not installed here (mothership only) — skipped"
    else
        ck "merge: runs"                                 0 "${mrc}"
        ck "merge: .node keeps the Host"                 tappaas3 "$(jq -r '[..|objects|select(has("node"))|.node][0]' "${cd_}/backup.json")"
        ck "merge: placementState stays node"            node     "$(jq -r '[..|objects|select(has("placementState"))|.placementState][0]' "${cd_}/backup.json")"
        ck "merge: …while a new release field arrives"   1        "$(jq -r '[..|objects|select(has("newField"))|.newField][0]' "${cd_}/backup.json")"
    fi
    rm -f "${SCHEMA}"
else
    echo "  - merge chain: composed schema or converter unavailable here — skipped"
fi

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
