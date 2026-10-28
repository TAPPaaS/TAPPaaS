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
#   2. you pick it and confirm by typing its device name. A stick this script
#      wrote before (a FAT partition labelled TAPPAASKEYS holding
#      tappaas-keys.tar.enc) is NOT erased: only the four files below are
#      replaced, and anything else on it — an emergency signing key in
#      kingdom/, say — stays. Any other stick is ERASED (--format: erase a key
#      stick too)
#   3. you choose a password (twice, 12 characters or more) — keep it apart from
#      the stick; on a reused stick the new password replaces the old one
#   4. the stick gets one FAT32 partition labelled TAPPAASKEYS holding
#        tappaas-keys.tar.enc        the keys, AES-256-CBC, key from the password
#                                    by PBKDF2 (600 000 iterations, SHA-256)
#        tappaas-keys.tar.enc.sha256
#        keys-from-usb.sh            the restore, in plain text — it must work
#                                    when the mothership is the thing that is gone
#        README.txt                  what this is, and the bare openssl command
#   5. it is decrypted back from the stick and compared key by key, then ejected.
#      The new keys are written beside the old ones and only replace them once
#      they have read back correctly, so a failed rewrite leaves the old keys
#      on the stick.
#
# The keys never touch a disk in the clear on the node: they travel over ssh in a
# pipe into openssl (the mothership has none), and the password is passed as the
# first line of that pipe — never on a command line, never in a file.
#
# Non-interactive (the web console runs it this way; nothing is asked):
#   --device <path>    the stick, as the list above names it (/dev/sdb): no
#                      "insert and press Enter", no choice. It must be one of
#                      the node's USB disks and not in use, or nothing happens.
#   --yes              no typed confirmation — the caller has shown the operator
#                      what will be erased (or kept). Needs --device.
#   --password-stdin   the password is the first line of stdin, read once, not
#                      asked twice; under 12 characters the stick is not touched.
#                      Needs --device. Never on the command line.
# Everything after the password — format or reuse, write, verify, record,
# eject — is the same either way.
#
# Usage: keys-to-usb.sh [--node <node>] [--format] [--device <path> [--yes] [--password-stdin]]
# Exit:  0 written and verified · 1 failed · 2 usage

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=keys-from-usb.sh disable=SC1091
. "${HERE}/keys-from-usb.sh"

FORMAT=0 DEVICE="" YES=0 PW_STDIN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --node) USBK_NODE="${2:?--node needs a node name}"; shift 2 ;;
        --format) FORMAT=1; shift ;;
        --device) DEVICE="${2:?--device needs the path of the stick, e.g. /dev/sdb}"; shift 2 ;;
        --yes) YES=1; shift ;;
        --password-stdin) PW_STDIN=1; shift ;;
        -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) usbk_say "unknown option: $1"; exit 2 ;;
    esac
done
[[ "${YES}" -eq 1 && -z "${DEVICE}" ]] && { usbk_say "--yes goes with --device: nothing is confirmed for a stick that was not chosen"; exit 2; }
[[ "${PW_STDIN}" -eq 1 && -z "${DEVICE}" ]] && { usbk_say "--password-stdin goes with --device"; exit 2; }

command -v backup-manager >/dev/null || usbk_die "run this on the mothership (backup-manager is not here)"
command -v jq >/dev/null || usbk_die "jq is needed"
usbk_on "command -v openssl >/dev/null && command -v sfdisk >/dev/null && command -v mkfs.vfat >/dev/null" \
    || usbk_die "${USBK_NODE} is not reachable as root, or lacks openssl/sfdisk/mkfs.vfat"

# --password-stdin: the first line of stdin, read before anything else can.
# usbk_on never reads stdin (ssh -n) and every usbk_on_stdin below pipes its
# own content, so after this line stdin is never touched again.
PW=""
if [[ "${PW_STDIN}" -eq 1 ]]; then
    IFS= read -r PW || true
    usbk_password_ok "${PW}" || usbk_die "the password is shorter than 12 characters — the stick was not touched"
fi

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
_exp="$(backup-manager key export --file "${PLAIN}" 2>&1)" || { printf '%s\n' "${_exp}" >&2; usbk_die "key export failed"; }
NKEYS="$(find "${PLAIN}/${USBK_KEYDIR}" -name '*.key' | wc -l | tr -d ' ')"
[[ "${NKEYS}" -gt 0 ]] || usbk_die "the escrow holds no keys — nothing to copy"

# ── the stick ───────────────────────────────────────────────────────
usbk_say ""
if [[ -z "${DEVICE}" ]]; then
    usbk_say "Insert the USB stick into ${USBK_NODE}, then press Enter."
    IFS= read -r _ || true
fi
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
    [[ -z "${DEVICE}" ]] || usbk_die "no USB stick on ${USBK_NODE} that may be written — ${DEVICE} was not touched"
    usbk_say "No USB stick seen on ${USBK_NODE}. Insert one and press Enter (q to quit)."
    IFS= read -r a || a=q; [[ "${a}" == q ]] && usbk_die "no USB stick"
done
usbk_say "USB disks on ${USBK_NODE}:"
pick=""
for i in "${!cands[@]}"; do
    IFS=$'\t' read -r d size desc <<<"${cands[$i]}"
    usbk_say "  $((i + 1))) ${d}  $(usbk_human "${size}")  ${desc}"
    [[ "${d}" == "${DEVICE}" ]] && pick=$((i + 1))
done
if [[ -n "${DEVICE}" ]]; then
    [[ -n "${pick}" ]] || usbk_die "${DEVICE} is not a USB stick on ${USBK_NODE} that may be written (those are: $(printf '%s\n' "${cands[@]}" | cut -f1 | paste -sd' ' -)) — nothing was touched"
elif [[ ${#cands[@]} -eq 1 ]]; then pick=1
else printf 'Which one? [1-%s] ' "${#cands[@]}" >&2; IFS= read -r pick || pick=""; fi
[[ "${pick}" =~ ^[0-9]+$ && "${pick}" -ge 1 && "${pick}" -le ${#cands[@]} ]] || usbk_die "no stick chosen"
IFS=$'\t' read -r DISK size desc <<<"${cands[$((pick - 1))]}"
q="$(printf %q "${DISK}")"
usbk_say ""
usbk_say "${DISK}  $(usbk_human "${size}")  ${desc}"

# A key stick written before: rewrite its keys, keep everything else on it.
REUSE=0 KPART=""
if [[ "${FORMAT}" -eq 0 ]]; then
    KPART="$(usbk_key_partition "$(usbk_on "lsblk -J -l -o PATH,LABEL,TYPE,FSTYPE ${q}")")"
fi
if [[ -n "${KPART}" ]]; then
    probe="$(usbk_on "$(usbk_probe_cmd "${KPART}")")" || probe=""
    if grep -q '^USBK_KEYSTICK' <<<"${probe}"; then
        REUSE=1
        written="$(sed -n 's/^USBK_WRITTEN //p' <<<"${probe}")"
        mapfile -t keep < <(sed -n 's/^USBK_KEEP //p' <<<"${probe}")
        usbk_say "This is a TAPPaaS key stick${written:+ (${written})}."
        usbk_say "Its backup keys will be REPLACED. Nothing else on it is touched; it holds:"
        if [[ ${#keep[@]} -gt 0 ]]; then for f in "${keep[@]}"; do usbk_say "    ${f}"; done
        else usbk_say "    (nothing else)"; fi
        usbk_say "(To erase it instead: backup-manager key export --usb --format)"
    fi
fi
if [[ "${YES}" -eq 1 ]]; then
    # --yes: the caller showed the operator this stick and what happens to it.
    if [[ "${REUSE}" -eq 1 ]]; then usbk_say "Replacing the keys on it (--yes)."
    else usbk_say "EVERYTHING on it will be ERASED (--yes)."; fi
else
    if [[ "${REUSE}" -eq 1 ]]; then
        printf 'Replace the keys on it? Type %s to continue: ' "$(basename "${DISK}")" >&2
    else
        printf 'EVERYTHING on it will be ERASED. Type %s to continue: ' "$(basename "${DISK}")" >&2
    fi
    IFS= read -r confirm || confirm=""
    [[ "${confirm}" == "$(basename "${DISK}")" ]] || usbk_die "not confirmed — the stick was not touched"
fi

# ── the password (--password-stdin: read at the top, already checked) ─
if [[ "${PW_STDIN}" -eq 0 ]]; then
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
fi

# ── format, or mount the key stick as it is ─────────────────────────
if [[ "${REUSE}" -eq 1 ]]; then
    usbk_say "Opening the key stick ${KPART} on ${USBK_NODE}..."
    fmt="$(usbk_on "set -e
        m=\$(mktemp -d /run/tappaas-keys.XXXXXX)
        mount $(printf %q "${KPART}") \"\$m\" >&2
        echo \"USBK_MOUNTED $(printf %q "${KPART}") \$m\"")" || usbk_die "mounting ${KPART} failed — the stick was not touched"
else
usbk_say "Formatting ${DISK} on ${USBK_NODE}..."
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
fi
read -r _ PART MNT < <(grep -E '^USBK_(FORMATTED|MOUNTED) ' <<<"${fmt}" | tail -1)
[[ "${PART}" == /dev/* && "${MNT}" == /run/tappaas-keys.* ]] \
    || usbk_die "preparing ${DISK} did not report its partition and mount point (got: ${fmt})"

# ── write ───────────────────────────────────────────────────────────
qm="$(printf %q "${MNT}")"
# Beside the old keys first: they are replaced only once the new copy has read
# back correctly (below), so a failure leaves a reused stick as it was.
usbk_say "Encrypting ${NKEYS} key(s) onto the stick..."
{ printf '%s\n' "${PW}"; tar -C "${PLAIN}" -cf - "${USBK_KEYDIR}"; } \
    | usbk_on_stdin "IFS= read -r pw; openssl enc -e ${USBK_CIPHER} -salt -pass fd:3 -out ${qm}/${USBK_BLOB}.new 3< <(printf %s \"\$pw\")" \
    || { usbk_on "rm -f ${qm}/${USBK_BLOB}.new" || true; usbk_die "writing the encrypted keys failed$([[ "${REUSE}" -eq 1 ]] && echo " — the old keys on the stick are unchanged")"; }

# ── verify: read the new copy back and compare every key ────────────
usbk_say "Reading it back..."
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-keys-verify.XXXXXX")"
printf '%s\n' "${PW}" | usbk_on_stdin "$(usbk_decrypt_cmd "${MNT}/${USBK_BLOB}.new")" | tar -C "${VERIFY}" -xf - \
    || { usbk_on "rm -f ${qm}/${USBK_BLOB}.new" || true; usbk_die "the stick could not be read back — do not rely on it"; }
unset PW
for k in "${PLAIN}/${USBK_KEYDIR}"/*.key; do
    cmp -s "${k}" "${VERIFY}/${USBK_KEYDIR}/$(basename "${k}")" \
        || { usbk_on "rm -f ${qm}/${USBK_BLOB}.new" || true; usbk_die "$(basename "${k}") on the stick differs from the escrow — do not rely on it"; }
done
usbk_on "mv -f ${qm}/${USBK_BLOB}.new ${qm}/${USBK_BLOB} && (cd ${qm} && sha256sum ${USBK_BLOB} > ${USBK_BLOB}.sha256)" \
    || usbk_die "could not put the new keys in place of the old ones"
usbk_say "  ✓ all ${NKEYS} key(s) read back from the stick, identical to the escrow"
# Record what the stick holds, so `backup-manager key status` (and the health
# check) can tell when a key changes after it. From the copy READ BACK: that is
# what the stick holds, not what was meant to go on it.
backup-manager key stamp --dir "${VERIFY}/${USBK_KEYDIR}" --label "${USBK_NODE}: ${desc:-$(basename "${DISK}")}" >/dev/null \
    || usbk_warn "the stick is good, but could not be recorded — backup-manager key status will still ask for one"
usbk_on_stdin "cat > ${qm}/keys-from-usb.sh" < "${HERE}/keys-from-usb.sh"
usbk_on_stdin "cat > ${qm}/README.txt" <<README
TAPPaaS backup encryption keys — written $(date '+%Y-%m-%d %H:%M') from $(hostname -s)

tappaas-keys.tar.enc holds every key that decrypts this site's backups:
  pve-storage-<storage>.key   VM and container backups (the Proxmox storage key)
  <host>.key                  each host's filesystem capture (config/, /etc/secrets)
encrypted with the password chosen when this stick was written. Without the
password the stick is useless; without the keys, so are the backups.

To restore:
  - on the mothership:          backup-manager key import --usb   (stick in tappaas1)
  - on a node, mothership lost: mount the stick, then as root run its script:
                                bash /mnt/<stick>/keys-from-usb.sh
  It decrypts, imports, and puts the storage key back on the cluster.

By hand (any machine with openssl and tar):
  openssl enc -d ${USBK_CIPHER} -in tappaas-keys.tar.enc | tar -xf -

Keep this stick OFF-SITE, and a second one like it somewhere else: one stick
is one point of failure. Rewrite both whenever a key changes.

Rewriting it (backup-manager key export --usb, this stick in a node) replaces
only these four files: tappaas-keys.tar.enc, its .sha256, keys-from-usb.sh and
README.txt. Anything else you keep on it — an emergency signing key in
kingdom/, say — is left as it is.
README
usbk_on "sync"

# ── eject ───────────────────────────────────────────────────────────
usbk_on "umount ${qm} && rmdir ${qm}" || usbk_die "could not unmount the stick"
MNT=""
usbk_eject "${DISK}"
usbk_say ""
usbk_say "Done. Remove the stick from ${USBK_NODE} and keep it OFF-SITE; keep the password elsewhere."
usbk_say "Make a SECOND stick (backup-manager key export --usb again) and keep it at a different place."

usbk_say "To restore: backup-manager key import --usb (or, mothership lost, the stick's keys-from-usb.sh on a node)."
