#!/usr/bin/env bash
#
# keys-from-usb.sh — bring TAPPaaS's backup encryption keys back from a USB stick
# that keys-to-usb.sh wrote (ADR-012 §2.5.1, RESTORE.md §0).
#
# The stick holds tappaas-keys.tar.enc: the escrowed keys (tappaas-backup-keys/),
# tar'd and encrypted with openssl AES-256-CBC, key from the password by PBKDF2
# (600 000 iterations, SHA-256). A copy of THIS script and a README travel on the
# stick in plain text, because the mothership may be the thing that is gone.
#
# Run it where you are:
#
#   on the mothership (tappaas user)  — the stick goes into a node (default
#       tappaas1); the keys are decrypted there, streamed back over ssh, and
#       imported into the escrow (backup-manager key import). Then
#       `module-manager module update backup` puts the storage key back on the
#       cluster — offered at the end.
#
#   on a node, as root (the mothership is lost) — the stick is in this node; the
#       keys land in /root/tappaas-backup-keys, and it offers to put the VM
#       backup storage key on the cluster, so `qmrestore` of the mothership's own
#       encrypted backup works (RESTORE.md §5.2).
#
#   from the stick itself — mount it on a node and run
#       bash /mnt/<stick>/keys-from-usb.sh
#
# Usage: keys-from-usb.sh [--node <node>]      (--node: mothership mode only)
# Exit:  0 keys restored · 1 failed · 2 usage
#
# keys-to-usb.sh sources this file for the shared helpers (usbk_*); only a direct
# run reaches main.

set -euo pipefail

USBK_LABEL="TAPPAASKEYS"                 # FAT label: 11 characters at most
USBK_BLOB="tappaas-keys.tar.enc"
USBK_KEYDIR="tappaas-backup-keys"
USBK_CIPHER="-aes-256-cbc -pbkdf2 -iter 600000 -md sha256"
USBK_NODE="${USBK_NODE:-tappaas1}"
# Tests only: let loop devices stand in for USB sticks (they carry no TRAN).
USBK_ALLOW_LOOP="${USBK_ALLOW_LOOP:-0}"

usbk_say()  { printf '%s\n' "$*" >&2; }
usbk_warn() { printf 'WARNING: %s\n' "$*" >&2; }
usbk_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── pure ─────────────────────────────────────────────────────────────

# usbk_candidates <lsblk-json> — whole USB disks, as TSV: path size-bytes label.
# lsblk -J -b -d -o NAME,PATH,SIZE,TRAN,TYPE,VENDOR,MODEL,SERIAL. A SATA/NVMe
# disk, an optical drive or a ZFS volume is never offered. Whether a USB disk is
# in use (mounted, pool, LVM) is asked separately, of the node.
usbk_candidates() {
    jq -r --arg loop "${USBK_ALLOW_LOOP}" '
        .blockdevices[]
        | select((.type == "disk" and .tran == "usb") or ($loop == "1" and .type == "loop"))
        | [ .path, (.size | tostring),
            ([.vendor, .model, (if .serial then "serial \(.serial)" else empty end)]
             | map(select(. != null) | gsub("^ +| +$"; "")) | map(select(. != "")) | join(" "))
          ] | @tsv' <<<"$1"
}

# usbk_labelled <lsblk-json> — partitions labelled TAPPAASKEYS, one path per line.
# lsblk -J -l -o PATH,LABEL,TYPE (flat list, partitions included).
usbk_labelled() {
    jq -r --arg l "${USBK_LABEL}" '.blockdevices[] | select(.label == $l) | .path' <<<"$1"
}

# usbk_key_partition <lsblk-json> — the partition of a key stick this script's
# twin wrote: label TAPPAASKEYS and a FAT file system. lsblk -J -l -o
# PATH,LABEL,TYPE,FSTYPE on the chosen disk. Empty when there is none.
usbk_key_partition() {
    jq -r --arg l "${USBK_LABEL}" '
        [.blockdevices[] | select(.type == "part" and .label == $l and .fstype == "vfat") | .path]
        | first // empty' <<<"$1"
}

# usbk_probe_cmd <partition> — node-side: mount it read-only, and say whether it
# holds the encrypted keys (USBK_KEYSTICK), when it was written (USBK_WRITTEN,
# the README's first line) and every other top-level entry on it (USBK_KEEP), the
# things a rewrite leaves alone. Unmounted again whatever happens.
usbk_probe_cmd() {
    local p; p="$(printf %q "$1")"
    printf '%s' "m=\$(mktemp -d /run/tappaas-keys.XXXXXX) || exit 1
mount -o ro ${p} \"\$m\" 2>/dev/null || { rmdir \"\$m\"; exit 1; }
[ -f \"\$m/${USBK_BLOB}\" ] && echo USBK_KEYSTICK
[ -f \"\$m/README.txt\" ] && head -1 \"\$m/README.txt\" | sed 's/^TAPPaaS backup encryption keys — //; s/^/USBK_WRITTEN /'
for f in \"\$m\"/* \"\$m\"/.[!.]*; do
  [ -e \"\$f\" ] || continue
  case \"\${f##*/}\" in ${USBK_BLOB}|${USBK_BLOB}.sha256|${USBK_BLOB}.new|keys-from-usb.sh|README.txt) continue ;; esac
  if [ -d \"\$f\" ]; then echo \"USBK_KEEP \${f##*/}/\"; else echo \"USBK_KEEP \${f##*/}\"; fi
done
umount \"\$m\"; rmdir \"\$m\""
}

# usbk_human <bytes> — 31.0 GB
usbk_human() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

# usbk_password_ok <pw> — 12 characters or more. The stick is the one copy of
# every backup key that leaves the building; its password is all that guards it.
usbk_password_ok() { [[ ${#1} -ge 12 ]]; }

# ── where the stick is: this node, or a node over ssh ─────────────────

USBK_LOCAL=0
# usbk_on <command> — run on the stick's node, as root. stdin is not read.
usbk_on() {
    if [[ "${USBK_LOCAL}" -eq 1 ]]; then bash -c "$1" </dev/null
    else ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${USBK_NODE}.mgmt.internal" "$1"; fi
}
# usbk_on_stdin <command> — the same, feeding this script's stdin to it.
usbk_on_stdin() {
    if [[ "${USBK_LOCAL}" -eq 1 ]]; then bash -c "$1"
    else ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${USBK_NODE}.mgmt.internal" "$1"; fi
}

# usbk_in_use <disk> — rc 0 when any part of it is mounted, swap, or a ZFS/LVM/RAID
# member: never offered, never erased.
usbk_in_use() {
    usbk_on "lsblk -nP -o MOUNTPOINT,FSTYPE $(printf %q "$1")" \
        | grep -qE 'MOUNTPOINT="[^"]+"|FSTYPE="(zfs_member|LVM2_member|swap|linux_raid_member)"'
}

# usbk_eject <disk> — flush and let it go.
usbk_eject() {
    usbk_on "sync; blockdev --flushbufs $(printf %q "$1") 2>/dev/null; eject $(printf %q "$1") 2>/dev/null || true"
}

# usbk_decrypt_cmd <blob-path> — node-side command: first stdin line is the
# password (never on a command line, never in a file), the plain tar to stdout.
usbk_decrypt_cmd() {
    printf '%s' "IFS= read -r pw; openssl enc -d ${USBK_CIPHER} -pass fd:3 -in $(printf %q "$1") 3< <(printf %s \"\$pw\")"
}

# ── restore ──────────────────────────────────────────────────────────

usbk_read_password() {
    local pw
    printf 'Password of the key stick: ' >&2
    IFS= read -r -s pw; printf '\n' >&2
    printf '%s' "${pw}"
}

# usbk_find_blob — print the path of the encrypted keys on the node. The stick is
# mounted read-only under a fresh directory; that directory is printed second,
# for the unmount. When this script runs FROM the stick, its own copy is used.
usbk_find_blob() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "${USBK_LOCAL}" -eq 1 && -f "${here}/${USBK_BLOB}" ]]; then
        printf '%s\t\n' "${here}/${USBK_BLOB}"; return 0
    fi
    local json parts part mnt n
    while :; do
        json="$(usbk_on "lsblk -J -l -o PATH,LABEL,TYPE")" || usbk_die "cannot list ${USBK_NODE}'s disks"
        parts="$(usbk_labelled "${json}")"
        n="$(grep -c . <<<"${parts}" || true)"
        [[ "${n}" -ge 1 ]] && break
        usbk_say "No key stick (label ${USBK_LABEL}) seen on ${USBK_NODE}. Insert it, then press Enter (q to quit)."
        local a; IFS= read -r a || a=q; [[ "${a}" == q ]] && usbk_die "no key stick"
    done
    part="$(head -1 <<<"${parts}")"
    [[ "${n}" -eq 1 ]] || usbk_warn "${n} key sticks are inserted — using ${part}"
    mnt="$(usbk_on "d=\$(mktemp -d /run/tappaas-keys.XXXXXX) && mount -o ro $(printf %q "${part}") \"\$d\" && echo \"\$d\"")" \
        || usbk_die "could not mount ${part} on ${USBK_NODE}"
    usbk_on "test -f $(printf %q "${mnt}/${USBK_BLOB}")" \
        || { usbk_on "umount $(printf %q "${mnt}"); rmdir $(printf %q "${mnt}")"; usbk_die "${part} has no ${USBK_BLOB} — not a key stick written by keys-to-usb.sh"; }
    printf '%s\t%s\t%s\n' "${mnt}/${USBK_BLOB}" "${mnt}" "${part}"
}

usbk_release() {   # <mount-dir> <partition>
    [[ -n "$1" ]] || return 0
    usbk_on "umount $(printf %q "$1") && rmdir $(printf %q "$1")" || usbk_warn "could not unmount $1 on ${USBK_NODE}"
    usbk_eject "$(usbk_on "lsblk -no PKNAME $(printf %q "$2")" | sed 's|^|/dev/|')"
}

# usbk_restore_to <dest-dir> — decrypt the stick's keys into <dest-dir>/tappaas-backup-keys.
usbk_restore_to() {
    local dest="$1" blob mnt part pw sum want n
    IFS=$'\t' read -r blob mnt part < <(usbk_find_blob)
    usbk_say "Key stick found: ${blob}"
    if usbk_on "test -f $(printf %q "${blob}.sha256")"; then
        sum="$(usbk_on "sha256sum < $(printf %q "${blob}") | cut -d' ' -f1")"
        want="$(usbk_on "cut -d' ' -f1 < $(printf %q "${blob}.sha256")")"
        [[ "${sum}" == "${want}" ]] || { usbk_release "${mnt}" "${part}"; usbk_die "the stick's checksum does not match — the copy on it is damaged"; }
        usbk_say "  checksum ok"
    fi
    pw="$(usbk_read_password)"
    ( umask 077; mkdir -p "${dest}" )
    if ! printf '%s\n' "${pw}" | usbk_on_stdin "$(usbk_decrypt_cmd "${blob}")" | tar --no-same-owner -C "${dest}" -xf - 2>/dev/null; then
        rm -rf "${dest:?}/${USBK_KEYDIR}"
        usbk_release "${mnt}" "${part}"
        usbk_die "could not decrypt — wrong password, or not a key stick"
    fi
    usbk_release "${mnt}" "${part}"
    n="$(find "${dest}/${USBK_KEYDIR}" -name '*.key' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${n}" -gt 0 ]] || usbk_die "decrypted, but no keys inside"
    chmod 700 "${dest}/${USBK_KEYDIR}"; chmod 600 "${dest}/${USBK_KEYDIR}"/*
    usbk_say "  ✓ ${n} key(s) decrypted into ${dest}/${USBK_KEYDIR} — you can remove the stick"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) USBK_NODE="${2:?--node needs a node name}"; shift 2 ;;
            -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
            *) usbk_say "unknown option: $1"; exit 2 ;;
        esac
    done
    command -v jq >/dev/null || usbk_die "jq is needed"

    if command -v pvesm >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
        # ── on a node: the mothership may be gone ──
        USBK_LOCAL=1; USBK_NODE="$(hostname -s)"
        command -v openssl >/dev/null || usbk_die "openssl is needed"
        local dest=/root
        usbk_restore_to "${dest}"
        local keys="${dest}/${USBK_KEYDIR}" k store enc
        for k in "${keys}"/pve-storage-*.key; do
            [[ -f "${k}" ]] || continue
            store="$(basename "${k}" .key)"; store="${store#pve-storage-}"
            enc="/etc/pve/priv/storage/${store}.enc"
            pvesm status --storage "${store}" >/dev/null 2>&1 || { usbk_say "  storage ${store} is not configured here — skipping its key"; continue; }
            if [[ -s "${enc}" ]]; then
                if cmp -s "${k}" "${enc}"; then usbk_say "  ${store} already carries this key"
                else usbk_warn "${store} carries a DIFFERENT key — left alone; backups made with the stick's key need it: ${k}"; fi
                continue
            fi
            printf 'Put this key on storage %s, so its backups can be restored (the mothership'"'"'s among them)? [y/N] ' "${store}" >&2
            local a; IFS= read -r a || a=""
            if [[ "${a}" == [yY]* ]]; then
                pvesm set "${store}" --encryption-key "$(cat "${k}")" >/dev/null && usbk_say "  ✓ ${store} can decrypt its backups again"
            fi
        done
        usbk_say ""
        usbk_say "Next (RESTORE.md §5.2): qmrestore <volid> 130 --storage <pool>; qm start 130; then copy"
        usbk_say "${keys} to the new mothership and run: backup-manager key import <that-dir>"
        usbk_say "Delete ${keys} when that is done — it holds every backup key in the clear."
    elif command -v backup-manager >/dev/null 2>&1; then
        # ── on the mothership: the stick is in a node ──
        # Global, not local: the EXIT trap that deletes the decrypted copy runs
        # after main has returned.
        USBK_DEST="$(mktemp -d "${HOME}/tappaas-keys-restore.XXXXXX")"
        trap 'rm -rf "${USBK_DEST:?}"' EXIT
        local dest="${USBK_DEST}"
        usbk_say "Insert the key stick into ${USBK_NODE}."
        usbk_restore_to "${dest}"
        backup-manager key import --file "${dest}/${USBK_KEYDIR}"
        # The stick holds these keys: record it, as writing a stick does — or a
        # rebuilt mothership asks for a stick that it was just restored from.
        backup-manager key stamp --dir "${dest}/${USBK_KEYDIR}" --label "${USBK_NODE}: read back" >/dev/null \
            || usbk_warn "the keys are imported, but the stick could not be recorded (backup-manager key status)"
        printf 'Put the storage key back on the cluster now (module-manager module update backup)? [y/N] ' >&2
        local a; IFS= read -r a || a=""
        [[ "${a}" == [yY]* ]] && module-manager module update backup
        usbk_say "The decrypted copy is deleted; the keys are in the escrow (/etc/secrets/backup-fs)."
    else
        usbk_die "run this on the mothership (tappaas) or on a Proxmox node as root"
    fi
}

# An `if`, not `[[ … ]] && main`: sourced, that line returns 1 — and under the
# set -e above, it would end the script that sourced it (keys-to-usb.sh).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
