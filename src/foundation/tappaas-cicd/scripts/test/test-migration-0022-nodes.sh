#!/usr/bin/env bash
# test-migration-0022-nodes.sh — the fixture test for migration 0022 (#872).
#
# hrossen's config (fixtures/0022-hrossen: site.json with hardware.nodes[]
# tappaas1 [tanka1, tankb1], tappaas3 [tanka1, tankc1], tappaas2 [tanka1], and
# the pvehost instances tappaas1-3 with no storagePools). Before → after,
# --check writes nothing, applying twice is a no-op, the backup holds what it
# rewrote, an instance's own pools win, and a node without its instance (or
# with an archived one) is refused with every file as it was.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0022-nodes-are-pvehost-instances.sh"
FIX="${HERE}/fixtures/0022-hrossen"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${FIX}/site.json" ]] || { echo "  ✗ the hrossen fixtures are not in ${FIX}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0022.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

fresh() { rm -rf "${CFG}"; mkdir -p "${CFG}"; cp "${FIX}"/*.json "${CFG}/"; }
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0022" bash "${M}" "$@" 2>&1; }
cfg() { jq -c "$2" "${CFG}/$1"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }

# ── hrossen as it is ──
fresh
before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check: exit 0"                                   0 "${rc}"
ck "--check: says what it would do"                    yes "$([[ "${out}" == *"would: tappaas3: storagePools"* && "${out}" == *"would: remove hardware"* ]] && echo yes || echo no)"
ck "--check: writes nothing"                           "${before}" "$(snap)"
out="$(run)"; rc=$?
ck "hrossen's config: exit 0"                          0 "${rc}"
ck "…tappaas1 carries tanka1, tankb1"                  '["tanka1","tankb1"]' "$(cfg tappaas1.json .storagePools)"
ck "…tappaas2 carries tanka1"                          '["tanka1"]' "$(cfg tappaas2.json .storagePools)"
ck "…tappaas3 carries tanka1, tankc1"                  '["tanka1","tankc1"]' "$(cfg tappaas3.json .storagePools)"
ck "…the instances are otherwise as they were"         "$(jq -c . "${FIX}/tappaas3.json")" "$(cfg tappaas3.json 'del(.storagePools)')"
ck "…site.json has no hardware"                        false "$(cfg site.json 'has("hardware")')"
ck "…and is otherwise as it was"                       "$(jq -c 'del(.hardware)' "${FIX}/site.json")" "$(cfg site.json .)"
ck "…the backup holds site.json as it was"             "$(jq -c . "${FIX}/site.json")" "$(jq -c . "${CFG}/.migrations/backup/0022/site.json")"
ck "…and each instance it rewrote"                     "$(jq -c . "${FIX}/tappaas2.json")" "$(jq -c . "${CFG}/.migrations/backup/0022/tappaas2.json")"
after="$(snap)"
out="$(run)"; rc=$?
ck "a second run: exit 0"                              0 "${rc}"
ck "…has nothing to do"                                yes "$([[ "${out}" == *"nothing to migrate"* ]] && echo yes || echo no)"
ck "…and changes nothing"                              "${after}" "$(snap)"

# ── the bash and TypeScript readers see the same nodes before and after ──
. "${CICD}/lib/cluster-nodes.sh"
fresh
pre="$(tappaas_cluster_nodes_json "${CFG}" | jq -c .)"
run >/dev/null
ck "the node list is the same before and after (pools included)" "${pre}" "$(tappaas_cluster_nodes_json "${CFG}" | jq -c .)"

# ── an instance that already records its pools keeps them ──
fresh
jq '.storagePools = ["tanka1"]' "${FIX}/tappaas1.json" > "${CFG}/tappaas1.json"
out="$(run)"; rc=$?
ck "an instance with its own pools: exit 0"            0 "${rc}"
ck "…keeps them"                                       '["tanka1"]' "$(cfg tappaas1.json .storagePools)"
ck "…and the difference is said"                       yes "$([[ "${out}" == *"tappaas1: keeps the storagePools its record has"* ]] && echo yes || echo no)"
ck "…the others are moved"                             '["tanka1","tankc1"]' "$(cfg tappaas3.json .storagePools)"

# ── refusals: every file as it was ──
fresh
rm "${CFG}/tappaas2.json"
before="$(snap)"
out="$(run)"; rc=$?
ck "a node with no instance: exit 1"                   1 "${rc}"
ck "…names it and how to register it"                  yes "$([[ "${out}" == *"tappaas2 has no pvehost instance"*"is missing"*"module-manager module adopt tappaas2.mgmt.internal"* ]] && echo yes || echo no)"
ck "…changes nothing"                                  "${before}" "$(snap)"
ck "…not even the nodes that have one"                 null "$(cfg tappaas1.json .storagePools)"
ck "…and writes no backup"                             no "$([[ -e "${CFG}/.migrations/backup/0022" ]] && echo yes || echo no)"

fresh
jq '.status = "archived"' "${FIX}/tappaas3.json" > "${CFG}/tappaas3.json"
before="$(snap)"
out="$(run)"; rc=$?
ck "a node whose instance is archived: exit 1"         1 "${rc}"
ck "…says so"                                          yes "$([[ "${out}" == *"tappaas3"*"is archived"* ]] && echo yes || echo no)"
ck "…changes nothing"                                  "${before}" "$(snap)"

fresh
echo '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/debianhost","address":"10.0.0.11"}' > "${CFG}/tappaas2.json"
before="$(snap)"
out="$(run)"; rc=$?
ck "a node whose config is another module's: exit 1"   1 "${rc}"
ck "…changes nothing"                                  "${before}" "$(snap)"

fresh
jq '.hardware.nodes[1].storagePools = "tanka1"' "${FIX}/site.json" > "${CFG}/site.json"
before="$(snap)"
out="$(run)"; rc=$?
ck "storagePools that is not a list: exit 1"           1 "${rc}"
ck "…changes nothing"                                  "${before}" "$(snap)"

fresh
jq '.hardware.nodes += [{"storagePools": []}]' "${FIX}/site.json" > "${CFG}/site.json"
before="$(snap)"
out="$(run)"; rc=$?
ck "an entry with no name: exit 1"                     1 "${rc}"
ck "…changes nothing"                                  "${before}" "$(snap)"

# ── nothing to do ──
fresh
jq '.hardware = {"nodes": []}' "${FIX}/site.json" > "${CFG}/site.json"
out="$(run)"; rc=$?
ck "an empty node list: exit 0, hardware goes"         "0 false" "${rc} $(cfg site.json 'has("hardware")')"
rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no site.json: exit 0"                              0 "${rc}"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
