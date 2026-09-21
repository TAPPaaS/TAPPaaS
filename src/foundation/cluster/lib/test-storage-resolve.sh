#!/usr/bin/env bash
#
# test-storage-resolve.sh — unit test for the storage pool a guest is built on (#692).
#
# `tanka1` used to be the fallback whatever node the guest landed on, and nothing
# checked the node had it. On makerfloss (tappaas1/2 carry tanka1, tappaas3 carries
# tankc1) four of seven deep VM-creation variants died at `qm importdisk` with
# Proxmox's "storage 'tanka1' is not available on node 'tappaas3'" — after the
# 413 MB image had been downloaded, and naming a pool nobody had written down.
#
# The four functions are lifted out of Create-TAPPaaS-VM.sh (which otherwise runs
# on a Proxmox node) with `pvesh` and the module JSON stubbed, so the rule is
# tested without a cluster.
#
# Usage: ./test-storage-resolve.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../Create-TAPPaaS-VM.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^config_declares() {/,/^}/p;/^node_storage_json() {/,/^}/p;/^image_pools() {/,/^}/p;/^resolve_storage() {/,/^}/p' "${SRC}")"
[[ -n "${FN}" ]] || { echo "FAIL: the storage helpers are not in ${SRC}"; exit 1; }
bash -n <(printf '%s' "${FN}") 2>/dev/null || { echo "FAIL: extracted helpers do not parse"; exit 1; }

# run <node> <config-json> <pvesh-json>  → resolved pool on stdout, diagnostics on stderr
run() {
    local node="$1" cfg="$2" pve="$3"
    PVE_JSON="${pve}" JSON_IN="${cfg}" bash -c '
        JSON="${JSON_IN}"
        # Colour names the real script defines; unset here.
        RD=""; YW=""; DGN=""; CL=""; BOLD=""
        warn() { echo "WARN: $*" >&2; }
        error() { echo "ERROR: $*" >&2; }
        die() { error "$*"; exit 1; }
        get_config_value() {
            local key="$1" default="${2:-}"
            local v
            v="$(echo "${JSON}" | jq -r --arg K "$key" "
                    if has(\$K) then .[\$K]
                    else [(.config // {}) | to_entries[] | select(.value|has(\$K)) | .value[\$K]][0]
                    end // empty")"
            [ -n "${v}" ] && printf "%s" "${v}" || printf "%s" "${default}"
        }
        # Stub Proxmox: the node the caller asked about decides the answer.
        pvesh() {
            local path="$2"   # pvesh get <path> --output-format json
            local node="${path#/nodes/}"; node="${node%/storage}"
            # UNREACHABLE stands for an API that cannot be asked at all, which is
            # not the same answer as a node with no storage.
            [ "${PVE_JSON}" = "UNREACHABLE" ] && return 1
            echo "${PVE_JSON}" | jq -c --arg N "${node}" ".[\$N] // []"
        }
        '"${FN}"'
        resolve_storage "$1" tanka1
    ' _ "${node}" 2>&1
}

# A cluster shaped like makerfloss: the third node has its own pool.
PVE='{
  "tappaas1": [{"storage":"tanka1","type":"zfspool","content":"images,rootdir","active":1,"enabled":1},
               {"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas3": [{"storage":"tankc1","type":"zfspool","content":"images,rootdir","active":1,"enabled":1},
               {"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas4": [{"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas5": [{"storage":"tanka1","type":"zfspool","content":"rootdir","active":1,"enabled":1}],
  "tappaas6": [{"storage":"tanka1","type":"zfspool","content":"images","active":0,"enabled":1}]
}'

NO_STORAGE='{"vmname":"t","config":{"cluster:vm":{"cores":1}}}'
DECLARED_A='{"vmname":"t","config":{"cluster:vm":{"storage":"tanka1"}}}'
DECLARED_C='{"vmname":"t","config":{"cluster:vm":{"storage":"tankc1"}}}'
FLAT_A='{"vmname":"t","storage":"tanka1"}'

# ── the unchanged estate: every node carries tanka1 ─────────────────────────
ck "an undeclared pool on a node that HAS tanka1 stays tanka1" \
   "tanka1" "$(run tappaas1 "${NO_STORAGE}" "${PVE}")"
ck "a declared tanka1 on that node is honoured" \
   "tanka1" "$(run tappaas1 "${DECLARED_A}" "${PVE}")"

# ── the makerfloss shape: the node has a different pool ─────────────────────
out="$(run tappaas3 "${NO_STORAGE}" "${PVE}")"
ckin "an undeclared pool resolves to the node's own ZFS pool" "tankc1" "${out}"
ckin "…and says so rather than switching silently"           "WARN"   "${out}"

# A pool the operator DID write down is not quietly replaced: that is their word.
out="$(run tappaas3 "${DECLARED_A}" "${PVE}")"
ckin "a declared pool the node lacks is refused"        "does not have it" "${out}"
ckin "…the refusal names the node"                      "tappaas3"         "${out}"
ckin "…and lists what the node does offer"              "tankc1"           "${out}"
ck   "a declared pool the node HAS is honoured"         "tankc1" "$(run tappaas3 "${DECLARED_C}" "${PVE}")"

# Pattern A is not the only layout — a flat field is a declaration too.
ckin "a flat declared pool is checked the same way" "does not have it" "$(run tappaas3 "${FLAT_A}" "${PVE}")"

# ── nodes with nothing usable ───────────────────────────────────────────────
out="$(run tappaas4 "${NO_STORAGE}" "${PVE}")"
ckin "a node with no ZFS pool for disks is refused, not guessed at" "no ZFS pool" "${out}"
# 'rootdir' without 'images' cannot hold a VM disk; an inactive pool is not there.
ckin "a pool that cannot hold images does not count"  "no ZFS pool" "$(run tappaas5 "${NO_STORAGE}" "${PVE}")"
ckin "an inactive pool does not count"                "no ZFS pool" "$(run tappaas6 "${NO_STORAGE}" "${PVE}")"
ckin "a node Proxmox lists no storage for is refused, not defaulted" \
     "no ZFS pool" "$(run tappaas9 "${NO_STORAGE}" "${PVE}")"

# ── Proxmox unreachable is not the same as "the node has nothing" ───────────
# A query failure must not block a build that would have worked before.
ck "an unanswerable API falls back to the schema default" \
   "tanka1" "$(run tappaas1 "${NO_STORAGE}" 'UNREACHABLE')"
ck "…and a declared pool is not refused on a query failure" \
   "tankc1" "$(run tappaas1 "${DECLARED_C}" 'UNREACHABLE')"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
