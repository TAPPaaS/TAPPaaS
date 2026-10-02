#!/usr/bin/env bash
#
# keys-to-usb.sh — the out-of-band copy of TAPPaaS's backup encryption keys,
# written to a USB stick in a node (ADR-012 §2.5.1, RESTORE.md §0).
#
# The keys are escrowed on the mothership — inside the system a full rebuild
# recreates — so they need a copy that leaves the building. The mothership is a
# VM and sees no USB port, so the stick goes into a node (default tappaas1):
#
#   1. you insert the stick; the node's USB disks are listed — never one that is
#      mounted, swap, or part of a ZFS pool, LVM or RAID
#   2. you pick it and confirm by typing its device name: it is ERASED
#   3. you choose a password (twice, 12 characters or more) — keep it apart from
#      the stick
#   4. the stick gets one FAT32 partition labelled TAPPAASKEYS holding
#        tappaas-keys.tar.enc        the keys, AES-256-CBC, key from the password
#                                    by PBKDF2 (600 000 iterations, SHA-256)
#        tappaas-keys.tar.enc.sha256
#        keys-from-usb.sh            the restore, in plain text — it must work
#                                    when the mothership is the thing that is gone
#        README.txt                  what this is, and the bare openssl command
#   5. it is decrypted back from the stick and compared key by key, then ejected
#
# The keys never touch a disk in the clear on the node: they travel over ssh in a
# pipe into openssl (the mothership has none), and the password is passed as the
# first line of that pipe — never on a command line, never in a file.
#
# Usage: keys-to-usb.sh [--node <node>]
# Exit:  0 written and verified · 1 failed · 2 usage

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=keys-from-usb.sh disable=SC1091
. "${HERE}/keys-from-usb.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node) USBK_NODE="${2:?--node needs a node name}"; shift 2 ;;
        -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) usbk_say "unknown option: $1"; exit 2 ;;
    esac
done

command -v backup-manager >/dev/null || usbk_die "run this on the mothership (backup-manager is not here)"
command -v jq >/dev/null || usbk_die "jq is needed"
usbk_on "command -v openssl >/dev/null && command -v sfdisk >/dev/null && command -v mkfs.vfat >/dev/null" \
    || usbk_die "${USBK_NODE} is not reachable as root, or lacks openssl/sfdisk/mkfs.vfat"

PLAIN="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-keys.XXXXXX")"
VERIFY=""
MNT="" PART="" DISK=""
cleanup() {
    rm -rf "${PLAIN:?}" ${VERIFY:+"${VERIFY}"}
    # Unmount by asking the DISK where it is mounted — not from MNT, which a
    # failure may never have set (or set to garbage: a real stick's sfdisk
    # printed into what was read as the mount point).
    if [[ -n "${DISK}" ]]; then
        usbk_on "for m in \$(lsblk -nrpo MOUNTPOINT $(printf %q "${DISK}") | grep '^/run/tappaas-keys\.'); do umount \"\$m\" && rmdir \"\$m\"; done" || true
    fi
}
trap cleanup EXIT

# ── the keys ────────────────────────────────────────────────────────
# Quietly: its own output tells a person what to do with a PLAIN export (and
# recommends this very script). Shown only if it fails.
_exp="$(backup-manager key export "${PLAIN}" 2>&1)" || { printf '%s\n' "${_exp}" >&2; usbk_die "key export failed"; }
NKEYS="$(find "${PLAIN}/${USBK_KEYDIR}" -name '*.key' | wc -l | tr -d ' ')"
[[ "${NKEYS}" -gt 0 ]] || usbk_die "the escrow holds no keys — nothing to copy"

# ── the stick ───────────────────────────────────────────────────────
usbk_say ""
usbk_say "Insert the USB stick into ${USBK_NODE}, then press Enter."
IFS= read -r _ || true
while :; do
    json="$(usbk_on "lsblk -J -b -d -o NAME,PATH,SIZE,TRAN,TYPE,VENDOR,MODEL,SERIAL")" || usbk_die "cannot list ${USBK_NODE}'s disks"
    mapfile -t all < <(usbk_candidates "${json}")
    cands=()
    for c in "${all[@]}"; do
        d="${c%%$'\t'*}"
        if usbk_in_use "${d}"; then usbk_say "  (not offered: ${d} is in use — mounted, swap, or part of a pool/LVM/RAID)"
        else cands+=("${c}"); fi
    done
    [[ ${#cands[@]} -gt 0 ]] && break
    usbk_say "No USB stick seen on ${USBK_NODE}. Insert one and press Enter (q to quit)."
    IFS= read -r a || a=q; [[ "${a}" == q ]] && usbk_die "no USB stick"
done
usbk_say "USB disks on ${USBK_NODE}:"
for i in "${!cands[@]}"; do
    IFS=$'\t' read -r d size desc <<<"${cands[$i]}"
    usbk_say "  $((i + 1))) ${d}  $(usbk_human "${size}")  ${desc}"
done
if [[ ${#cands[@]} -eq 1 ]]; then pick=1
else printf 'Which one? [1-%s] ' "${#cands[@]}" >&2; IFS= read -r pick || pick=""; fi
[[ "${pick}" =~ ^[0-9]+$ && "${pick}" -ge 1 && "${pick}" -le ${#cands[@]} ]] || usbk_die "no stick chosen"
IFS=$'\t' read -r DISK size desc <<<"${cands[$((pick - 1))]}"
usbk_say ""
usbk_say "${DISK}  $(usbk_human "${size}")  ${desc}"
printf 'EVERYTHING on it will be ERASED. Type %s to continue: ' "$(basename "${DISK}")" >&2
IFS= read -r confirm || confirm=""
[[ "${confirm}" == "$(basename "${DISK}")" ]] || usbk_die "not confirmed — the stick was not touched"

# ── the password ────────────────────────────────────────────────────
for try in 1 2 3; do
    printf 'Password for the stick (12+ characters; keep it apart from the stick): ' >&2
    IFS= read -r -s pw1; printf '\n' >&2
    printf 'Again: ' >&2
    IFS= read -r -s pw2; printf '\n' >&2
    if [[ "${pw1}" != "${pw2}" ]]; then usbk_say "  they differ — again"
    elif ! usbk_password_ok "${pw1}"; then usbk_say "  shorter than 12 characters — again"
    else break; fi
    [[ "${try}" -lt 3 ]] || usbk_die "no password set — the stick was not touched"
done
PW="${pw1}"; unset pw1 pw2

# ── format ──────────────────────────────────────────────────────────
usbk_say "Formatting ${DISK} on ${USBK_NODE}..."
q="$(printf %q "${DISK}")"
# Every tool's chatter goes to stderr: only the marked last line is the answer.
# (sfdisk on a real stick — an old hybrid-ISO one — printed "calling ioctl to
# re-read partition table: Success" on stdout, which was read as the partition
# and its mount point.)
fmt="$(usbk_on "set -e
    { wipefs -a -q ${q}
      printf 'label: dos\ntype=c\n' | sfdisk -q ${q}
      udevadm settle; } >&2
    p=\$(lsblk -lnpo NAME,TYPE ${q} | awk '\$2==\"part\" {print \$1; exit}')
    [ -n \"\$p\" ]
    { wipefs -a -q \"\$p\"; mkfs.vfat -F 32 -n ${USBK_LABEL} \"\$p\" >/dev/null 2>&1; } >&2
    m=\$(mktemp -d /run/tappaas-keys.XXXXXX)
    mount \"\$p\" \"\$m\" >&2
    echo \"USBK_FORMATTED \$p \$m\"")" || usbk_die "formatting ${DISK} failed"
read -r _ PART MNT < <(grep '^USBK_FORMATTED ' <<<"${fmt}" | tail -1)
[[ "${PART}" == /dev/* && "${MNT}" == /run/tappaas-keys.* ]] \
    || usbk_die "formatting ${DISK} did not report its partition and mount point (got: ${fmt})"

# ── write ───────────────────────────────────────────────────────────
qm="$(printf %q "${MNT}")"
usbk_say "Encrypting ${NKEYS} key(s) onto the stick..."
{ printf '%s\n' "${PW}"; tar -C "${PLAIN}" -cf - "${USBK_KEYDIR}"; } \
    | usbk_on_stdin "IFS= read -r pw; openssl enc -e ${USBK_CIPHER} -salt -pass fd:3 -out ${qm}/${USBK_BLOB} 3< <(printf %s \"\$pw\") && (cd ${qm} && sha256sum ${USBK_BLOB} > ${USBK_BLOB}.sha256)" \
    || usbk_die "writing the encrypted keys failed"
usbk_on_stdin "cat > ${qm}/keys-from-usb.sh" < "${HERE}/keys-from-usb.sh"
usbk_on_stdin "cat > ${qm}/README.txt" <<README
TAPPaaS backup encryption keys — written $(date '+%Y-%m-%d %H:%M') from $(hostname -s)

tappaas-keys.tar.enc holds every key that decrypts this site's backups:
  pve-storage-<storage>.key   VM and container backups (the Proxmox storage key)
  <host>.key                  each host's filesystem capture (config/, /etc/secrets)
encrypted with the password chosen when this stick was written. Without the
password the stick is useless; without the keys, so are the backups.

To restore, run keys-from-usb.sh (on this stick):
  - on the mothership:          bash keys-from-usb.sh   (stick in tappaas1)
  - on a node, mothership lost: mount the stick, then as root:
                                bash /mnt/<stick>/keys-from-usb.sh
  It decrypts, imports, and puts the storage key back on the cluster.

By hand (any machine with openssl and tar):
  openssl enc -d ${USBK_CIPHER} -in tappaas-keys.tar.enc | tar -xf -

Keep this stick OFF-SITE, and a second one like it somewhere else: one stick
is one point of failure. Rewrite both whenever a key changes.
README
usbk_on "sync"

# ── verify: read it back and compare every key ──────────────────────
usbk_say "Reading it back..."
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-keys-verify.XXXXXX")"
printf '%s\n' "${PW}" | usbk_on_stdin "$(usbk_decrypt_cmd "${MNT}/${USBK_BLOB}")" | tar -C "${VERIFY}" -xf - \
    || usbk_die "the stick could not be read back — do not rely on it"
unset PW
for k in "${PLAIN}/${USBK_KEYDIR}"/*.key; do
    cmp -s "${k}" "${VERIFY}/${USBK_KEYDIR}/$(basename "${k}")" \
        || usbk_die "$(basename "${k}") on the stick differs from the escrow — do not rely on it"
done
usbk_say "  ✓ all ${NKEYS} key(s) read back from the stick, identical to the escrow"

# ── eject ───────────────────────────────────────────────────────────
usbk_on "umount ${qm} && rmdir ${qm}" || usbk_die "could not unmount the stick"
MNT=""
usbk_eject "${DISK}"
usbk_say ""
usbk_say "Done. Remove the stick from ${USBK_NODE} and keep it OFF-SITE; keep the password elsewhere."
usbk_say "Make a SECOND stick the same way and keep it at a different place (RESTORE.md §0)."
usbk_say "To restore: keys-from-usb.sh (on the mothership, or from the stick on a node)."
