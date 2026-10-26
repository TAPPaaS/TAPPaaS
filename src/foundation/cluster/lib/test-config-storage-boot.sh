#!/usr/bin/env bash
#
# test-config-storage-boot.sh — the boot pool in config-storage.sh (ADR-037 D1).
#
# A mirrored rpool boots from either disk only when every member's EFI system
# partition is registered with proxmox-boot-tool: ensure_boot_esps registers the
# one that is missing (formatting it only when it holds no filesystem), leaves a
# registered one alone, says when a member has no ESP, and does nothing on one
# disk. boot_pool_storage finds the storage on rpool/data. The functions are
# lifted out of config-storage.sh (which needs a Proxmox node) with zpool,
# lsblk, blkid and proxmox-boot-tool stubbed.
#
# Usage: ./test-config-storage-boot.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../config-storage.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^boot_pool_storage() {/,/^}/p;/^boot_pool_members() {/,/^}/p;/^disk_esp() {/,/^}/p;/^esp_registered() {/,/^}/p;/^ensure_boot_esps() {/,/^}/p' "${SRC}")"
[[ "$(grep -c '() {$' <<<"${FN}")" -eq 5 ]] || { echo "FAIL: the boot-pool functions are not all in ${SRC}"; exit 1; }
eval "${FN}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
ESP_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
BOOT_UUIDS_FILE="${T}/proxmox-boot-uuids"
LOG="${T}/log"
info() { echo "INFO $*" >> "${LOG}"; }
warn() { echo "WARN $*" >> "${LOG}"; }
debug() { :; }
GN="" CL=""

# A two-disk rpool: sda3 and sdb3, ESPs on sda2 and sdb2.
ZS=$'  pool: rpool\n\trpool ONLINE\n\t  mirror-0 ONLINE\n\t    /dev/sda3 ONLINE\n\t    /dev/sdb3 ONLINE'
zpool()    { printf '%s\n' "${ZS}"; }
readlink() { echo "${@: -1}"; }
lsblk() {
    case "$*" in
        *"PKNAME /dev/sda3"*) echo sda ;;
        *"PKNAME /dev/sdb3"*) echo sdb ;;
        *"PATH,PARTTYPE /dev/sda"*) printf '/dev/sda1 21686148-6449-6e6f-744e-656564454649\n/dev/sda2 %s\n/dev/sda3 6a898cc3-1dd2-11b2-99a6-080020736631\n' "${ESP_TYPE^^}" ;;
        *"PATH,PARTTYPE /dev/sdb"*) [[ "${SDB_ESP:-1}" == 1 ]] && printf '/dev/sdb2 %s\n' "${ESP_TYPE}"; printf '/dev/sdb3 6a898cc3-1dd2-11b2-99a6-080020736631\n' ;;
    esac
}
declare -A UUID=([/dev/sda2]="AAAA-1111" [/dev/sdb2]="BBBB-2222") FSTYPE=([/dev/sda2]="vfat" [/dev/sdb2]="vfat")
blkid() {
    local dev="${@: -1}"
    case "$*" in
        *"-s UUID"*) echo "${UUID[$dev]:-}" ;;
        *"-s TYPE"*) echo "${FSTYPE[$dev]:-}" ;;
    esac
}
proxmox-boot-tool() { echo "PBT $*" >> "${LOG}"; [[ "$1" == init ]] && echo "${UUID[$2]}" >> "${BOOT_UUIDS_FILE}"; return 0; }

reset() { : > "${LOG}"; printf '%s\n' "$@" > "${BOOT_UUIDS_FILE}"; }

echo "── a mirror with both ESPs registered"
reset AAAA-1111 BBBB-2222
ensure_boot_esps; ck "rc 0" 0 "$?"
ck "proxmox-boot-tool is not called" "" "$(grep PBT "${LOG}")"

echo "── a mirror whose second ESP is not registered"
reset AAAA-1111
ensure_boot_esps; ck "rc 0" 0 "$?"
ck "only the missing one is initialised" "PBT init /dev/sdb2" "$(grep PBT "${LOG}")"
ck "…and it is said" "yes" "$(grep -q "also boots from sdb" "${LOG}" && echo yes || echo no)"

echo "── an ESP with no filesystem is formatted first"
reset AAAA-1111; FSTYPE[/dev/sdb2]=""
ensure_boot_esps
ck "format, then init" "PBT format /dev/sdb2|PBT init /dev/sdb2" "$(grep PBT "${LOG}" | paste -sd'|' -)"
FSTYPE[/dev/sdb2]="vfat"

echo "── a member without an ESP"
reset AAAA-1111; SDB_ESP=0
ensure_boot_esps; ck "rc 1" 1 "$?"
ck "…said as a warning" "yes" "$(grep -q "WARN rpool member sdb has no EFI system partition" "${LOG}" && echo yes || echo no)"
SDB_ESP=1

echo "── one disk: nothing to mirror"
ZS=$'  pool: rpool\n\trpool ONLINE\n\t  /dev/sda3 ONLINE'
reset
ensure_boot_esps; ck "rc 0" 0 "$?"
ck "proxmox-boot-tool is not called" "" "$(grep PBT "${LOG}")"

echo "── the boot pool's storage"
CFG="${T}/storage.cfg"
printf 'dir: local\n\tpath /var/lib/vz\n\nzfspool: local-zfs\n\tpool rpool/data\n\tsparse\n\tcontent images,rootdir\n\nzfspool: tanka1\n\tpool tanka1\n' > "${CFG}"
FN2="$(declare -f boot_pool_storage | sed "s#/etc/pve/storage.cfg#${CFG}#")"; eval "${FN2}"
ck "local-zfs is on rpool/data" "local-zfs" "$(boot_pool_storage)"
printf 'zfspool: tanka1\n\tpool tanka1\n' > "${CFG}"
ck "no storage on rpool/data: nothing" "" "$(boot_pool_storage)"

grep -q 'root_fstype)" != "zfs"' "${SRC}" && ck "one ext4 boot disk is refused" yes yes || ck "one ext4 boot disk is refused" yes no
grep -q 'LIST_ONLY:-0}" == 1 ]] || ensure_boot_esps' "${SRC}" && ck "--list does not touch the ESPs" yes yes || ck "--list does not touch the ESPs" yes no

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
