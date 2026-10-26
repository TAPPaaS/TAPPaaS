#!/usr/bin/env bash
#
# test-storage-placement.sh — lib/storage-placement.sh (ADR-037 D1): a module's
# storage is a preference; the node's own pools are taken in order — the same
# class, any tanka<N>, any other ZFS pool, the boot pool — and the boot pool
# keeps 20 % free. The
# storage.cfg readers find the boot pool's storage and a storage's dataset.
#
# Usage: ./test-storage-placement.sh   (exit 0 = all passed)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=storage-placement.sh
. "${HERE}/storage-placement.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
nl() { printf '%s\n' "$@"; }

echo "── sp_choose"
ck "the storage asked for, when the node has it" tanka1 "$(sp_choose tanka1 "$(nl tanka1 tankb1 local-zfs)" "$(nl tanka1 tankb1 local-zfs)" local-zfs)"
ck "a non-tank storage asked for, when present" fastpool "$(sp_choose fastpool "$(nl fastpool local-zfs)" "$(nl fastpool local-zfs)" local-zfs)"
ck "tanka1 missing: tanka2 (same class)" tanka2 "$(sp_choose tanka1 "$(nl tanka2 tanka10 local-zfs)" "$(nl tanka10 tanka2 local-zfs)" local-zfs)"
ck "tankb1 missing: tankb2 before tanka1" tankb2 "$(sp_choose tankb1 "$(nl tanka1 tankb2)" "$(nl tanka1 tankb2)" "")"
ck "tankb1 missing, no tankb: any tanka" tanka1 "$(sp_choose tankb1 "$(nl tanka1 local-zfs)" "$(nl tanka1 local-zfs)" local-zfs)"
ck "no tanka: another ZFS data pool before the boot pool" tankc1 "$(sp_choose tanka1 "$(nl tankc1 local-zfs)" "$(nl local-zfs tankc1)" local-zfs)"
ck "…a pool named otherwise too" fastpool "$(sp_choose tanka1 "$(nl fastpool local-zfs)" "$(nl fastpool local-zfs)" local-zfs)"
ck "…on a node without a boot pool (ext4 boot)" tankc1 "$(sp_choose tanka1 "$(nl tankc1 local)" "tankc1" "")"
ck "no tank pool at all: the boot pool" local-zfs "$(sp_choose tanka1 "$(nl local local-zfs)" "local-zfs" local-zfs)"
ck "a named pool missing, only the boot pool: there" local-zfs "$(sp_choose fastpool "local-zfs" "local-zfs" local-zfs)"
out="$(sp_choose tanka1 "local" "" "")"; rc=$?
ck "nothing to build on: rc 1" "1/" "${rc}/${out}"
ck "a directory storage is not a fallback" "1" "$(sp_choose tanka1 "$(nl local nfs-store)" "" local-zfs >/dev/null; echo $?)"
ck "the boot pool only when it can hold a guest" "1" "$(sp_choose tanka1 "local" "" local-zfs >/dev/null; echo $?)"

echo "── sizes and the reserve"
ck "8G" "$(( 8 * 1024 ** 3 ))" "$(sp_size_bytes 8G)"
ck "512m" "$(( 512 * 1024 ** 2 ))" "$(sp_size_bytes 512m)"
ck "1T" "$(( 1024 ** 4 ))" "$(sp_size_bytes 1T)"
ck "bytes" "4096" "$(sp_size_bytes 4096)"
ck "nonsense is 0" "0" "$(sp_size_bytes lots)"
G=$(( 1024 ** 3 ))
sp_reserve_ok $(( 100 * G )) $(( 50 * G )) $(( 30 * G )); ck "50 + 30 of 100: fits (20 % left)" 0 "$?"
sp_reserve_ok $(( 100 * G )) $(( 50 * G )) $(( 31 * G )); ck "50 + 31 of 100: refused" 1 "$?"
sp_reserve_ok 0 0 1; ck "an unknown pool size: refused" 1 "$?"

echo "── storage.cfg"
SP_STORAGE_CFG="$(mktemp)"; trap 'rm -f "${SP_STORAGE_CFG}"' EXIT
printf 'dir: local\n\tpath /var/lib/vz\n\nzfspool: local-zfs\n\tpool rpool/data\n\tsparse\n\tcontent images,rootdir\n\nzfspool: tanka1\n\tpool tanka1\n\tnodes tappaas1\n' > "${SP_STORAGE_CFG}"
ck "the boot pool's storage" local-zfs "$(sp_boot_storage)"
ck "local-zfs is rpool/data" rpool/data "$(sp_dataset local-zfs)"
ck "tanka1 is tanka1" tanka1 "$(sp_dataset tanka1)"
ck "an unknown storage: its own name" nosuch "$(sp_dataset nosuch)"
printf 'zfspool: tanka1\n\tpool tanka1\n' > "${SP_STORAGE_CFG}"
ck "no storage on rpool/data: none" "" "$(sp_boot_storage)"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
