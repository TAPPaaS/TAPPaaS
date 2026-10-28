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

echo "── a key stick written before is rewritten, not erased ──"
KS='{"blockdevices":[{"path":"/dev/sdb","label":null,"type":"disk","fstype":null},{"path":"/dev/sdb1","label":"TAPPAASKEYS","type":"part","fstype":"vfat"}]}'
ck "a FAT partition labelled TAPPAASKEYS is a key stick" "/dev/sdb1" "$(usbk_key_partition "${KS}")"
ck "the same label on another file system is not" "" \
   "$(usbk_key_partition '{"blockdevices":[{"path":"/dev/sdb1","label":"TAPPAASKEYS","type":"part","fstype":"ext4"}]}')"
ck "an unlabelled stick is not" "" \
   "$(usbk_key_partition '{"blockdevices":[{"path":"/dev/sdb1","label":"PHOTOS","type":"part","fstype":"vfat"}]}')"
P="$(usbk_probe_cmd /dev/sdb1)"
ck "the probe mounts it read-only" yes "$([[ "${P}" == *"mount -o ro /dev/sdb1"* ]] && echo yes || echo no)"
ck "…lists everything but the four files the rewrite replaces" yes \
   "$([[ "${P}" == *"tappaas-keys.tar.enc|tappaas-keys.tar.enc.sha256|tappaas-keys.tar.enc.new|keys-from-usb.sh|README.txt) continue"* ]] && echo yes || echo no)"
ck "…and unmounts it again" yes "$([[ "${P}" == *'umount "$m"; rmdir "$m"' ]] && echo yes || echo no)"
ck "a key stick is only reused when the blob is on it, and never with --format" yes \
   "$(grep -q "grep -q '^USBK_KEYSTICK'" "${TO}" && grep -q 'if \[\[ "${FORMAT}" -eq 0 \]\]; then' "${TO}" && echo yes || echo no)"
ck "reusing it asks for the device name too, and says what is kept" yes \
   "$(grep -q 'Replace the keys on it? Type %s to continue' "${TO}" && grep -q 'Nothing else on it is touched' "${TO}" && echo yes || echo no)"
ck "the new keys are written beside the old, read back, and only then moved into place" yes \
   "$(awk '/-out \$\{qm\}\/\$\{USBK_BLOB\}.new/ {w=NR} /usbk_decrypt_cmd "\$\{MNT\}\/\$\{USBK_BLOB\}.new"/ {v=NR} /mv -f \$\{qm\}\/\$\{USBK_BLOB\}.new/ {m=NR} END {print (w && v && m && w < v && v < m) ? "yes" : "no"}' "${TO}")"

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
ck "an ejected stick (no medium, size 0) is never a candidate" yes \
   "$(grep -q 'select((.size | tonumber) > 0)' "${FROM}" && echo yes || echo no)"
ck "a disk in use is never offered (mounted, swap, pool, LVM, RAID)" yes \
   "$(grep -q 'zfs_member|LVM2_member|swap|linux_raid_member' "${FROM}" && grep -q 'usbk_in_use "${d}"' "${TO}" && echo yes || echo no)"
ck "the stick is read back and compared before it is trusted" yes \
   "$(grep -q 'differs from the escrow — do not rely on it' "${TO}" && echo yes || echo no)"
ck "the format (or mount) step's answer is a marked line, never a tool's stdout" yes \
   "$(grep -q 'echo \\"USBK_FORMATTED' "${TO}" && grep -qF "grep -E '^USBK_(FORMATTED|MOUNTED) '" "${TO}" && grep -q 'echo \\"USBK_MOUNTED' "${TO}" && grep -q '"${MNT}" == /run/tappaas-keys.\*' "${TO}" && echo yes || echo no)"
ck "cleanup finds the stick's mounts from the disk, not from MNT" yes \
   "$(grep -q 'lsblk -nrpo MOUNTPOINT' "${TO}" && echo yes || echo no)"
ck "key export runs quietly (its PLAIN-copy advice is not for this script)" yes \
   "$(grep -q '_exp="$(backup-manager key export' "${TO}" && echo yes || echo no)"
ck "the stick's keys are recorded from the copy read back from it" yes \
   "$(grep -q 'backup-manager key stamp --dir "${VERIFY}/${USBK_KEYDIR}"' "${TO}" && echo yes || echo no)"
ck "…only after every key on it compared equal" yes \
   "$(awk '/differs from the escrow — do not rely on it/ {c=NR} /backup-manager key stamp/ {s=NR} END {print (c && s > c) ? "yes" : "no"}' "${TO}")"
ck "an import from a stick records it too" yes \
   "$(grep -q 'backup-manager key stamp --dir "${dest}/${USBK_KEYDIR}"' "${FROM}" && echo yes || echo no)"
ck "the restore script travels on the stick" yes "$(grep -q 'cat > ${qm}/keys-from-usb.sh' "${TO}" && echo yes || echo no)"

echo "── without a terminal (the web console): --device --yes --password-stdin ──"
# The option checks come before anything is touched or needed, so they run here.
bash "${TO}" --yes >/dev/null 2>&1;                       ck "--yes without --device is a usage error" 2 "$?"
bash "${TO}" --password-stdin >/dev/null 2>&1;            ck "--password-stdin without --device is a usage error" 2 "$?"
bash "${TO}" --device /dev/sdb --yes --password-stdin </dev/null >/dev/null 2>&1; ck "…together they are accepted (then the mothership check)" 1 "$?"
ck "--device skips 'insert the stick and press Enter'" yes \
   "$(awk '/^if \[\[ -z "\$\{DEVICE\}" \]\]; then/ {d=NR} /Insert the USB stick into/ {i=NR} END {print (d && i == d + 1) ? "yes" : "no"}' "${TO}")"
ck "…and must name a stick that is offered — in use or absent, nothing is touched" yes \
   "$(grep -q 'is not a USB stick on ${USBK_NODE} that may be written' "${TO}" && grep -q '\[\[ "${d}" == "${DEVICE}" \]\] && pick=' "${TO}" && echo yes || echo no)"
ck "--yes alone never skips the confirmation; it needs --device" yes \
   "$(grep -q '"${YES}" -eq 1 && -z "${DEVICE}" \]\] && { usbk_say' "${TO}" && echo yes || echo no)"
ck "the password from stdin is read before anything else reads stdin, and checked" yes \
   "$(awk '/IFS= read -r PW \|\| true/ {r=NR} /^PLAIN=/ {p=NR} /usbk_password_ok "\$\{PW\}" \|\| usbk_die/ {c=NR} END {print (r && p && c && r < c && c < p) ? "yes" : "no"}' "${TO}")"
ck "every node-side command either ignores stdin (ssh -n) or is fed its own pipe" "" \
   "$(grep -nE 'usbk_on_stdin' "${TO}" | grep -vE '^[0-9]+:#|\| usbk_on_stdin|usbk_on_stdin "cat > [^"]*" (<|<<)' )"
ck "with --password-stdin the password is asked for exactly never" yes \
   "$(grep -q 'if \[\[ "${PW_STDIN}" -eq 0 \]\]; then' "${TO}" && echo yes || echo no)"

echo "── round trip with openssl (the restore's own command) ──"
if command -v openssl >/dev/null && openssl enc -help 2>&1 | grep -c -- '-pbkdf2' >/dev/null; then
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
