#!/usr/bin/env bash
#
# test-config-storage-free.sh — which disks config-storage.sh counts as free (#405).
#
# The installer asked "Configure pool tankb1?" and "tankc1?" with no disk left to
# give them. It now skips a pool when no candidate is free: a disk an IMPORTED
# pool claims is listed but is no choice; an old, unimported label is.
# disk_zpool and free_disk_count are lifted out of config-storage.sh (which needs
# a Proxmox node and a TTY) with `zpool status -P` stubbed.
#
# Usage: ./test-config-storage-free.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../config-storage.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^disk_zpool() {/,/^}/p;/^free_disk_count() {/,/^}/p' "${SRC}")"
[[ "$(grep -c '() {$' <<<"${FN}")" -eq 2 ]] || { echo "FAIL: disk_zpool/free_disk_count not found in ${SRC}"; exit 1; }
eval "${FN}"

# `zpool status -P` of the imported pools; vdevs given as whole disks, so the
# parent lookup falls back to the device's own name.
ZS=""
zpool()    { printf '%s\n' "${ZS}"; }
readlink() { echo "${@: -1}"; }
lsblk()    { :; }

CAND_NAME=(sdb sdc sdd)
ZS=""
ck "no imported pool: every candidate is free" "3" "$(free_disk_count)"
ZS=$'  pool: tanka1\n\ttanka1 ONLINE\n\t  mirror-0 ONLINE\n\t    /dev/sdb ONLINE\n\t    /dev/sdc ONLINE'
ck "tanka1 holds two of three: one free" "1" "$(free_disk_count)"
ZS+=$'\n  pool: tankb1\n\ttankb1 ONLINE\n\t  /dev/sdd ONLINE'
ck "every candidate in an imported pool: none free (the pool is skipped)" "0" "$(free_disk_count)"
CAND_NAME=()
ck "no candidates at all: none free" "0" "$(free_disk_count)"

grep -q 'free_disk_count)" -eq 0' "${SRC}" && ck "the pool loop skips a pool when none is free" yes yes \
    || ck "the pool loop skips a pool when none is free" yes no

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
