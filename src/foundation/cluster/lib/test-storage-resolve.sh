#!/usr/bin/env bash
#
# test-storage-resolve.sh — unit test for the storage pool a guest is built on
# (#692, ADR-037 D1: a module's storage is a preference).
#
# `tanka1` used to be the fallback whatever node the guest landed on, and nothing
# checked the node had it. On makerfloss (tappaas1/2 carry tanka1, tappaas3 carries
# tankc1) four of seven deep VM-creation variants died at `qm importdisk` with
# Proxmox's "storage 'tanka1' is not available on node 'tappaas3'" — after the
# 413 MB image had been downloaded, and naming a pool nobody had written down.
#
# The functions are lifted out of Create-TAPPaaS-VM.sh (which otherwise runs on a
# Proxmox node) with lib/storage-placement.sh sourced and `pvesh`, `zpool`,
# storage.cfg and the module JSON stubbed, so the rule is tested without a cluster.
#
# Usage: ./test-storage-resolve.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../Create-TAPPaaS-VM.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^node_storage_json() {/,/^}/p;/^image_pools() {/,/^}/p;/^resolve_storage() {/,/^}/p' "${SRC}")"
LIB="${SCRIPT_DIR}/storage-placement.sh"
CFG="$(mktemp)"; trap 'rm -f "${CFG}"' EXIT
printf 'zfspool: local-zfs\n\tpool rpool/data\n\tcontent images,rootdir\n\nzfspool: tanka1\n\tpool tanka1\n\nzfspool: tankc1\n\tpool tankc1\n' > "${CFG}"
[[ -n "${FN}" ]] || { echo "FAIL: the storage helpers are not in ${SRC}"; exit 1; }
bash -n <(printf '%s' "${FN}") 2>/dev/null || { echo "FAIL: extracted helpers do not parse"; exit 1; }

# run <node> <config-json> <pvesh-json>  → STDOUT ONLY.
# This is the value the caller assigns to STORAGE, so it must be the pool name
# and nothing else. run_msgs() below keeps everything the operator was told.
run_raw() {
    local node="$1" cfg="$2" pve="$3"
    PVE_JSON="${pve}" JSON_IN="${cfg}" SP_STORAGE_CFG="${CFG}" ZPOOL_LIST="${ZPOOL_LIST:-1000000000000 100000000000}" bash -c '
        JSON="${JSON_IN}"
        # Colour names the real script defines; unset here.
        RD=""; YW=""; DGN=""; CL=""; BOLD=""
        # warn() prints to STDOUT, exactly as Create-TAPPaaS-VM.sh defines it.
        # A helper whose stdout IS a value has to redirect its own chatter, and
        # a stub that quietly sent this to stderr would hide that — it did,
        # once: the warning text landed in $STORAGE and the live run failed
        # with `qm disk import ... 400 too many arguments`.
        warn() { echo "WARN: $*"; }
        error() { echo "ERROR: $*" >&2; }
        die() { error "$*"; exit 1; }
        debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo "[Debug] $*" >&2; }
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
        # zpool list -Hp -o size,alloc <pool>: the boot pool, 1 TB with 100 GB used unless a case says otherwise.
        zpool() { echo "${ZPOOL_LIST}"; }
        . "'"${LIB}"'"
        '"${FN}"'
        resolve_storage "$1" tanka1 "${DISK:-8G}"
    ' _ "${node}"
}

# STDOUT only: the value STORAGE is assigned.
run() { run_raw "$1" "$2" "$3" 2>/dev/null; }

# Both streams: what the operator is actually told.
run_msgs() { run_raw "$1" "$2" "$3" 2>&1; }

# A cluster shaped like makerfloss: the third node has its own pool.
PVE='{
  "tappaas1": [{"storage":"tanka1","type":"zfspool","content":"images,rootdir","active":1,"enabled":1},
               {"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas3": [{"storage":"tankc1","type":"zfspool","content":"images,rootdir","active":1,"enabled":1},
               {"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas4": [{"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}],
  "tappaas5": [{"storage":"tanka1","type":"zfspool","content":"rootdir","active":1,"enabled":1}],
  "tappaas6": [{"storage":"tanka1","type":"zfspool","content":"images","active":0,"enabled":1}],
  "tappaas7": [{"storage":"local-zfs","type":"zfspool","content":"images,rootdir","active":1,"enabled":1},
               {"storage":"local","type":"dir","content":"images,iso","active":1,"enabled":1}]
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
# Exact, not a substring: a warning printed on stdout would end up inside
# STORAGE, and only an exact comparison sees that.
ck   "an undeclared pool resolves to the node's own ZFS pool, and nothing else" \
     "tankc1" "$(run tappaas3 "${NO_STORAGE}" "${PVE}")"
ckin "…and says so rather than switching silently" \
     "WARN" "$(run_msgs tappaas3 "${NO_STORAGE}" "${PVE}")"

# A declared pool is a preference too (ADR-037 D1): the node's own pool, said.
out="$(run_msgs tappaas3 "${DECLARED_A}" "${PVE}")"
ck   "a declared pool the node lacks falls back to the node's own pool" "tankc1" "$(run tappaas3 "${DECLARED_A}" "${PVE}")"
ckin "…with a warning naming both"                      "storage 'tanka1' is not on node 'tappaas3' — building on 'tankc1'" "${out}"
ck   "a declared pool the node HAS is honoured"         "tankc1" "$(run tappaas3 "${DECLARED_C}" "${PVE}")"
ck   "a flat declared pool is read the same way"        "tankc1" "$(run tappaas3 "${FLAT_A}" "${PVE}")"

# ── a one-disk node: ZFS on the boot disk, nothing else (ADR-037 D1) ────────
ck   "no data pool: the boot pool" "local-zfs" "$(run tappaas7 "${DECLARED_A}" "${PVE}")"
ckin "…said" "building on 'local-zfs'" "$(run_msgs tappaas7 "${DECLARED_A}" "${PVE}")"
out="$(DISK=850G run_msgs tappaas7 "${DECLARED_A}" "${PVE}")"
ckin "a disk that would take the boot pool under 20 % free is refused" "under 20 % free" "${out}"
ck   "…and prints no storage" "" "$(DISK=850G run tappaas7 "${DECLARED_A}" "${PVE}")"
ck   "600G (644 GB) on a 1 TB pool with 100 GB used fits" "local-zfs" "$(DISK=600G run tappaas7 "${DECLARED_A}" "${PVE}")"

# ── nodes with nothing usable ───────────────────────────────────────────────
out="$(run_msgs tappaas4 "${NO_STORAGE}" "${PVE}")"
ckin "a node with no ZFS pool for disks is refused, not guessed at" "no storage that can hold this guest" "${out}"
# 'rootdir' without 'images' cannot hold a VM disk; an inactive pool is not there.
ckin "a pool that cannot hold images does not count"  "no storage that can hold" "$(run_msgs tappaas5 "${NO_STORAGE}" "${PVE}")"
ckin "an inactive pool does not count"                "no storage that can hold" "$(run_msgs tappaas6 "${NO_STORAGE}" "${PVE}")"
ckin "a node Proxmox lists no storage for is refused, not defaulted" \
     "no storage that can hold" "$(run_msgs tappaas9 "${NO_STORAGE}" "${PVE}")"

# ── Proxmox unreachable is not the same as "the node has nothing" ───────────
# A query failure must not block a build that would have worked before.
ck "an unanswerable API falls back to the schema default" \
   "tanka1" "$(run tappaas1 "${NO_STORAGE}" 'UNREACHABLE')"
ck "…and a declared pool is not refused on a query failure" \
   "tankc1" "$(run tappaas1 "${DECLARED_C}" 'UNREACHABLE')"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
