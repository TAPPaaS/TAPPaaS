#!/usr/bin/env bash
#
# Unit tests for the pure CSV helpers in pbs-job.sh (issue #200).
# No cluster access — exercises the vmid-list add/remove/has logic only.
#
# Usage: ./test-pbs-job.sh   (exit 0 = all passed)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging stubs + CONFIG_DIR so the lib sources standalone.
info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
# shellcheck disable=SC2034  # read by the sourced pbs-job.sh (PBS_CONFIG_DIR)
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }

# shellcheck source=pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-job.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── _pbs_csv_has ─────────────────────────────────────────────────────
_pbs_csv_has "140,150,310" 150 && r=0 || r=1; ck_rc "has present"        0 "$r"
_pbs_csv_has "140,150,310" 311 && r=0 || r=1; ck_rc "has absent"         1 "$r"
_pbs_csv_has "140,150,310" 14  && r=0 || r=1; ck_rc "has no substr match" 1 "$r"   # 14 must not match 140
_pbs_csv_has "" 140               && r=0 || r=1; ck_rc "has on empty"      1 "$r"
_pbs_csv_has "140" 140            && r=0 || r=1; ck_rc "has single"        0 "$r"

# ── _pbs_csv_add (dedup + numeric sort) ──────────────────────────────
ck "add to empty"      "140"             "$(_pbs_csv_add "" 140)"
ck "add new (sorted)"  "140,150,310"     "$(_pbs_csv_add "150,310" 140)"
ck "add duplicate"     "140,150,310"     "$(_pbs_csv_add "140,150,310" 150)"
ck "add numeric order" "90,140,1000"     "$(_pbs_csv_add "140,1000" 90)"

# ── _pbs_csv_remove ──────────────────────────────────────────────────
ck "remove middle"     "140,310"         "$(_pbs_csv_remove "140,150,310" 150)"
ck "remove last→empty" ""                "$(_pbs_csv_remove "140" 140)"
ck "remove absent"     "140,150"         "$(_pbs_csv_remove "140,150" 999)"
ck "remove no substr"  "140"             "$(_pbs_csv_remove "140" 14)"   # 14 must not remove 140

# ── #457: one Host, one address; no guessing ─────────────────────────
PJ="$(mktemp -d)"; export PBS_CONFIG_DIR="${PJ}"   # read by pbs_node/pbs_node_addr
echo '{"placementState":"node","node":"tappaas3"}'      > "${PJ}/backup.json"
ck "pbs_node: the Host in .node"            "tappaas3" "$(pbs_node)"
echo '{"placementState":"node:tappaas2","node":""}'     > "${PJ}/backup.json"
ck "pbs_node: the pre-#600 form"             "tappaas2" "$(pbs_node)"
echo '{"placementState":"shim"}'                        > "${PJ}/backup.json"
pbs_node >/dev/null 2>&1 && ck "pbs_node: no Host → fails, never the first node" 1 0 \
                          || ck "pbs_node: no Host → fails, never the first node" 1 1
echo '{"kind":"machine","address":"10.0.0.90"}'         > "${PJ}/dh-test1.json"
ck "addr: a machine → its address"          "10.0.0.90"              "$(pbs_node_addr dh-test1)"
ck "addr: a node → <node>.mgmt.internal"    "tappaas3.mgmt.internal" "$(pbs_node_addr tappaas3)"
ck "addr: a DNS name (--pbs) → as is"       "sat.example.org"        "$(pbs_node_addr sat.example.org)"
rm -rf "${PJ}"

# ── #554: coverage across EVERY cluster job ──────────────────────────
JOBS='[
 {"id":"backup-mine","comment":"TAPPaaS-backup-vm-managed","vmid":"110,130","storage":"tappaas_backup","schedule":"21:00"},
 {"id":"backup-wk","comment":"TAPPaaS-backup-vm-managed-weekly","vmid":"340","storage":"tappaas_backup","schedule":"sat 21:00"},
 {"id":"backup-ops","comment":"ops nightly","vmid":"340,500","storage":"nfs","schedule":"02:00"},
 {"id":"backup-all","all":1,"exclude":"600","storage":"local","schedule":"sun 01:00"},
 {"id":"backup-off","comment":"old","vmid":"700","enabled":0,"storage":"nfs"},
 {"id":"backup-pool","pool":"lab","storage":"nfs","schedule":"03:00"}]'
cov() { pbs_jobs_covering "${JOBS}" "$1" | jq -r 'map("\(.jobId):\(.how):\(if .managed then "m" else "f" end):\(if .enabled then "on" else "off" end)") | join(" ")'; }
ck "coverage: managed + foreign explicit + all + pool" \
   "backup-wk:explicit:m:on backup-ops:explicit:f:on backup-all:all:f:on backup-pool:pool:f:on" "$(cov 340)"
ck "coverage: an --all exclude is honoured"  "backup-pool:pool:f:on" "$(cov 600)"
ck "coverage: a disabled job is marked off"  "backup-all:all:f:on backup-off:explicit:f:off backup-pool:pool:f:on" "$(cov 700)"
ck "coverage: 34 is not 340"                 "backup-all:all:f:on backup-pool:pool:f:on" "$(cov 34)"
ck "coverage: unparseable input → []"        "[]" "$(pbs_jobs_covering 'not json' 1)"

_pbs_ssh() { printf '%s\n' "${JOBS}"; }   # the cluster answers with JOBS
_pbs_foreign_guard 500 2>/dev/null && ck "guard: a foreign job naming the VM → leave it alone" 1 0 \
                                  || ck "guard: a foreign job naming the VM → leave it alone" 1 1
_pbs_foreign_guard 800 >/dev/null 2>&1 && ck "guard: only an --all / pool job → add anyway" 0 0 \
                                        || ck "guard: only an --all / pool job → add anyway" 0 1
_pbs_foreign_guard 700 >/dev/null 2>&1 && ck "guard: a DISABLED foreign job does not block" 0 0 \
                                        || ck "guard: a DISABLED foreign job does not block" 0 1
_pbs_ssh() { return 255; }                 # the cluster is silent
_pbs_foreign_guard 500 >/dev/null 2>&1 && ck "guard: cluster silent → proceed, never skip on a guess" 0 0 \
                                        || ck "guard: cluster silent → proceed, never skip on a guess" 0 1

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
