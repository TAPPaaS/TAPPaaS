#!/usr/bin/env bash
# TAPPaaS Module: immich — prepare an attached data disk (mediaStorage=attached)
#
# Interactive-only companion to install-service.sh: inspects the disk at slot
# scsi2 and offers the one-time preparation it needs, always with confirmation:
#
#   ext4, wrong/no label   → non-destructive relabel to "immich-data" (data kept)
#   blank (no filesystem)  → format ext4 (y/N prompt)
#   foreign filesystem     → kept by default; erasing requires typing 'erase'
#
# If no disk is attached yet it prints the exact attach commands and exits
# without changing anything. Safe to re-run at any time.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' 'immich')"
VMID="$(get_config_value 'vmid' '361')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

# Slot-stable device path inside the VM — see install-service.sh.
MEDIA_DEV="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2"

remote() { ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" "$1"; }

# $1 = question; $2 = 'erase' to require that exact word instead of y/N.
confirm() {
    warn "  ${GN}${BOLD}To cancel: press Ctrl+C, or just press Enter (default is No). Nothing has been changed yet.${CL}"
    local reply
    if [[ "${2:-}" == "erase" ]]; then
        read -r -p "  Type 'erase' to confirm, anything else cancels: " reply
        [[ "${reply}" == "erase" ]] || die "Aborted by operator (nothing was changed)"
    else
        read -r -p "  $1 [y/N] " reply
        case "${reply}" in
            y|Y|yes|Yes|YES) ;;
            *) die "Aborted by operator (nothing was changed)" ;;
        esac
    fi
}

echo ""
info "${BOLD}immich: prepare attached data disk${CL}"
info "  VM: ${VMNAME} (ID: ${VMID}) on ${NODE}"

[[ -t 0 ]] || die "This script is interactive by design (it asks before any change) — run it from a terminal."

qm config "${VMID}" >/dev/null 2>&1 \
  || die "VM ${VMID} does not exist yet. Run 'install-module.sh immich' first."

# ── No disk at scsi2: print attach instructions, change nothing ──────────────
if ! qm config "${VMID}" | grep -q '^scsi2:'; then
    if remote "test -e /dev/disk/by-label/immich-data" 2>/dev/null; then
        die "An 'immich-data' filesystem is already visible in the VM, but not at slot scsi2. Move that disk to scsi2 (check 'qm config ${VMID}', then reattach with 'qm set ${VMID} --scsi2 ...') — this script will not create a second data disk."
    fi
    info "VM ${VMID} has ${BOLD}no disk attached at slot scsi2${CL} (the data-disk slot)."
    info "Attach your disk on node ${BL}${NODE}${CL}, then re-run this script:"
    info "  USB / local disk (use by-id so it survives reboots; find it with 'ls -l /dev/disk/by-id/'):"
    info "    ${BL}qm set ${VMID} --scsi2 /dev/disk/by-id/<disk-id>${CL}"
    info "  iSCSI LUN from a NAS:"
    info "    ${BL}pvesm add iscsi media-iscsi --portal <NAS-IP> --target <iqn>${CL}"
    info "    ${BL}qm set ${VMID} --scsi2 media-iscsi:0.0.0.scsi-<lun>${CL}"
    info "For a new virtual disk instead, set \"mediaStorage\": \"allocate\" in immich.json;"
    info "for a NAS share, see INSTALL.md → Photo Storage → Path 3."
    exit 0
fi

# ── Disk present: inspect and offer the needed preparation ───────────────────
info "  Waiting for VM to be reachable..."
for _i in $(seq 1 12); do remote "exit 0" 2>/dev/null && break; sleep 5; done
remote "exit 0" 2>/dev/null || die "Cannot connect to ${IMMICH_HOST} — is the VM running?"
remote "test -e ${MEDIA_DEV}" 2>/dev/null \
  || die "scsi2 is configured but ${MEDIA_DEV} is not visible in the VM — reboot it (qm reboot ${VMID}) and re-run."

FS_TYPE=$(remote "sudo blkid -o value -s TYPE ${MEDIA_DEV} 2>/dev/null" || true)
FS_LABEL=$(remote "sudo blkid -o value -s LABEL ${MEDIA_DEV} 2>/dev/null" || true)
info "  Disk at scsi2: filesystem='${FS_TYPE:-none}' label='${FS_LABEL:-none}'"

if [[ "${FS_LABEL}" == "immich-data" ]]; then
    info "${GN}✓${CL} Disk is already prepared (ext4, label immich-data) — nothing to do."
    exit 0
elif [[ "${FS_TYPE}" == "ext4" ]]; then
    echo ""
    info "The disk has an ext4 filesystem but not the ${BOLD}immich-data${CL} label the VM mounts by."
    info "Relabelling is ${GN}non-destructive${CL} — all data on the disk is kept."
    confirm "Relabel the disk to 'immich-data' (keeps all data)?"
    remote "sudo e2label ${MEDIA_DEV} immich-data" \
      && info "  ${GN}✓${CL} Disk relabelled — data untouched" \
      || die "e2label failed — run manually on the VM: sudo e2label ${MEDIA_DEV} immich-data"
elif [[ -z "${FS_TYPE}" ]]; then
    echo ""
    warn "${BOLD}The disk at scsi2 is blank (no filesystem).${CL}"
    warn "  ${RD}${BOLD}About to FORMAT it (mkfs.ext4, label immich-data).${CL}"
    confirm "Format this blank disk?"
    remote "sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}" \
      && info "  ${GN}✓${CL} Disk formatted and labelled" \
      || die "mkfs.ext4 failed — format manually on the VM: sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}"
else
    echo ""
    warn "${BOLD}The disk at scsi2 carries a ${RD}${FS_TYPE}${CL}${BOLD} filesystem — it may hold your photos.${CL}"
    warn "  To ${GN}keep the data${CL}: cancel now and see INSTALL.md → Photo Storage → Path 2"
    warn "  (non-ext4 filesystems are mounted by editing immich.nix, no format needed)."
    warn "  To ${RD}ERASE the disk${CL} and start fresh, confirm below."
    confirm "" "erase"
    remote "sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}" \
      && info "  ${GN}✓${CL} Disk formatted and labelled" \
      || die "mkfs.ext4 failed — format manually on the VM: sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}"
fi

echo ""
info "${GN}✓${CL} Data disk ready. Re-run install-module.sh immich (or ./services/photostorage/install-service.sh) to mount and verify."
