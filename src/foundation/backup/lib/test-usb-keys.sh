#!/usr/bin/env bash
#
# test-usb-keys.sh — keys-to-usb.sh / keys-from-usb.sh: the parts that decide
# which disk may be erased, and how the password travels. The live write and
# read are run on a node against a loop device (RESTORE.md §0, 2026-10-02).
#
# Usage: ./test-usb-keys.sh   (exit 0 = all passed)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TO="${HERE}/../scripts/keys-to-usb.sh"
FROM="${HERE}/../scripts/keys-from-usb.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v jq >/dev/null || { echo "jq not found — cannot run here."; exit 77; }

# shellcheck source=../scripts/keys-from-usb.sh disable=SC1091
. "${FROM}"
set +e

echo "── which disks are offered ──"
LSBLK='{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":12000138625024,"tran":"sata","type":"disk","vendor":"ATA     ","model":"ST12000VN0008","serial":"ZZ30"},
 {"name":"sdb","path":"/dev/sdb","size":31004295168,"tran":"usb","type":"disk","vendor":"SanDisk ","model":"Ultra","serial":"4C53"},
 {"name":"sr0","path":"/dev/sr0","size":1073741312,"tran":"usb","type":"rom","vendor":"TSST","model":"DVD","serial":null},
 {"name":"nvme0n1","path":"/dev/nvme0n1","size":500107862016,"tran":"nvme","type":"disk","vendor":null,"model":"SanDisk SSD","serial":"25414"},
 {"name":"zd16","path":"/dev/zd16","size":34359738368,"tran":null,"type":"disk","vendor":null,"model":null,"serial":null},
 {"name":"loop3","path":"/dev/loop3","size":67108864,"tran":null,"type":"loop","vendor":null,"model":null,"serial":null}]}'
ck "only the USB disk — not SATA, NVMe, a USB optical drive or a ZFS volume" \
   "/dev/sdb 31004295168 SanDisk Ultra serial 4C53" "$(usbk_candidates "${LSBLK}" | tr '\t' ' ')"
ck "a loop device only in test mode" "/dev/sdb /dev/loop3" \
   "$(USBK_ALLOW_LOOP=1 usbk_candidates "${LSBLK}" | cut -f1 | paste -sd' ' -)"
ck "nothing USB: nothing offered" "" "$(usbk_candidates '{"blockdevices":[{"name":"sda","path":"/dev/sda","size":1,"tran":"sata","type":"disk"}]}')"
ck "size for people" "31.0 GB" "$(usbk_human 31004295168)"

echo "── finding the stick again ──"
ck "the partition labelled TAPPAASKEYS" "/dev/sdb1" \
   "$(usbk_labelled '{"blockdevices":[{"path":"/dev/sdb","label":null,"type":"disk"},{"path":"/dev/sdb1","label":"TAPPAASKEYS","type":"part"},{"path":"/dev/sdc1","label":"PHOTOS","type":"part"}]}')"
ck "the label fits FAT (11 characters)" yes "$([[ ${#USBK_LABEL} -le 11 ]] && echo yes || echo no)"

echo "── the password ──"
usbk_password_ok "short-pw";            ck "under 12 characters refused" 1 "$?"
usbk_password_ok "twelve chars";        ck "12 characters accepted" 0 "$?"
ck "the password is read from a pipe, never put on a command line" "" \
   "$(grep -nE -- '-pass (pass|env):|-k |-pass "\$' "${TO}" "${FROM}")"
ck "…it is the first line of stdin, handed to openssl as fd 3" yes \
   "$(grep -q 'IFS= read -r pw; openssl enc -d' "${FROM}" && grep -q -- '-pass fd:3' "${TO}" && echo yes || echo no)"
ck "the restore command contains no password" "" "$(usbk_decrypt_cmd /x/blob | grep -o 'secret' )"

echo "── what may be erased ──"
ck "the erase needs the device name typed back" yes \
   "$(grep -q 'Type %s to continue' "${TO}" && grep -q '"${confirm}" == "$(basename "${DISK}")"' "${TO}" && echo yes || echo no)"
ck "a disk in use is never offered (mounted, swap, pool, LVM, RAID)" yes \
   "$(grep -q 'zfs_member|LVM2_member|swap|linux_raid_member' "${FROM}" && grep -q 'usbk_in_use "${d}"' "${TO}" && echo yes || echo no)"
ck "the stick is read back and compared before it is trusted" yes \
   "$(grep -q 'differs from the escrow — do not rely on it' "${TO}" && echo yes || echo no)"
ck "the restore script travels on the stick" yes "$(grep -q 'cat > ${qm}/keys-from-usb.sh' "${TO}" && echo yes || echo no)"

echo "── round trip with openssl (the restore's own command) ──"
if command -v openssl >/dev/null && openssl enc -help 2>&1 | grep -q -- '-pbkdf2'; then
    T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
    mkdir -p "${T}/src/${USBK_KEYDIR}"; printf '{"kdf":null,"key":"k1"}' > "${T}/src/${USBK_KEYDIR}/pve-storage-x.key"
    # shellcheck disable=SC2086
    tar -C "${T}/src" -cf - "${USBK_KEYDIR}" | openssl enc -e ${USBK_CIPHER} -salt -pass pass:correct-horse-battery -out "${T}/blob"
    USBK_LOCAL=1
    mkdir -p "${T}/out"
    printf 'correct-horse-battery\n' | usbk_on_stdin "$(usbk_decrypt_cmd "${T}/blob")" | tar -C "${T}/out" -xf - 2>/dev/null
    ck "the right password gives the keys back" '{"kdf":null,"key":"k1"}' "$(cat "${T}/out/${USBK_KEYDIR}/pve-storage-x.key" 2>/dev/null)"
    mkdir -p "${T}/bad"
    printf 'wrong-password-here\n' | usbk_on_stdin "$(usbk_decrypt_cmd "${T}/blob")" 2>/dev/null | tar -C "${T}/bad" -xf - 2>/dev/null
    ck "a wrong one gives nothing" no "$([[ -f "${T}/bad/${USBK_KEYDIR}/pve-storage-x.key" ]] && echo yes || echo no)"
else
    echo "  (openssl with -pbkdf2 not here — round trip covered by the live test on a node)"
fi

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
