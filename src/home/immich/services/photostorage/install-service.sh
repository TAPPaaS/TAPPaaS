#!/usr/bin/env bash
# TAPPaaS Module: immich — photostorage service install
#
# Ensures the photo storage declared in immich.json ("mediaStorage") is
# present and mounted at /var/lib/immich (Immich's mediaLocation). Modes:
#
#   allocate — the module owns the disk: if slot scsi2 is empty, allocate a
#              fresh volume (mediaDiskStorage/mediaDiskSize) and format it.
#              Declaring this mode in the config is the consent; the only
#              thing ever formatted is the blank volume created seconds
#              earlier. An existing disk at scsi2 is never touched.
#   attached — the operator provides the disk (USB/iSCSI): verify only.
#              Never allocates or formats. Prepare the disk interactively
#              with setup-media-disk.sh (relabel/format with confirmation).
#   share    — /var/lib/immich is a network share mounted via immich.nix:
#              no disk, verify the mount only.
#
# Idempotent and safe to re-run in every mode.
#
# Called automatically by install-module.sh because immich provides "photostorage".
# Run directly for recovery:
#   ./services/photostorage/install-service.sh

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh immich

VMNAME="$(get_config_value 'vmname' 'immich')"
VMID="$(get_config_value 'vmid' '361')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'unset')"
MEDIA_STORAGE="$(get_config_value 'mediaDiskStorage' 'tankc1')"
MEDIA_SIZE="$(get_config_value 'mediaDiskSize' '500G')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SETUP_SCRIPT="./services/photostorage/setup-media-disk.sh"
MOUNT_POINT="/var/lib/immich"
PVE_HOST="${NODE}.mgmt.internal"

# Slot-stable device path inside the VM (QEMU stamps the drive id into the
# SCSI serial). Never address the data disk as /dev/sdX — the letters shuffle
# when other disks (iSCSI LUNs, USB, multipath) are present.
MEDIA_DEV="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2"

remote() { ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" "$1"; }
# qm/pvesm are Proxmox CLI tools — they only exist on the hypervisor node, not
# on this orchestrator host, so every call must be run over SSH against it.
pve() { ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${PVE_HOST}" "$1"; }

wait_for_vm() {
    for _i in $(seq 1 12); do
        remote "exit 0" 2>/dev/null && return 0
        sleep 5
    done
    die "Cannot connect to ${IMMICH_HOST} — is the VM running?"
}

echo ""
info "${BOLD}immich: photostorage service install${CL}"
info "  VM   : ${VMNAME} (ID: ${VMID}) on ${NODE}"
info "  Mode : ${MEDIA_MODE}"

case "${MEDIA_MODE}" in
    allocate|attached|share) ;;
    unset) die "Set \"mediaStorage\" in immich.json to allocate, attached, or share (see INSTALL.md → Photo Storage)." ;;
    *)     die "Unknown mediaStorage mode '${MEDIA_MODE}' — must be allocate, attached, or share." ;;
esac

# ── Step 1: Ensure the data disk exists (allocate/attached modes) ────────────
if [[ "${MEDIA_MODE}" != "share" ]] && ! pve "qm config ${VMID}" | grep -q '^scsi2:'; then
    # Wrong-slot guard: an immich-data label visible in the VM means the disk
    # exists at another slot — never create a second one. (Best-effort: skipped
    # if the VM is not reachable yet.)
    if remote "test -e /dev/disk/by-label/immich-data" 2>/dev/null; then
        die "An 'immich-data' filesystem is already visible in the VM, but not at slot scsi2. Move that disk to scsi2 (check 'qm config ${VMID}', then reattach with 'qm set ${VMID} --scsi2 ...') instead of creating a new one."
    fi

    if [[ "${MEDIA_MODE}" == "attached" ]]; then
        die "mediaStorage=attached, but VM ${VMID} has no disk at slot scsi2. Attach your disk (see INSTALL.md → Photo Storage → Path 2), prepare it with ${SETUP_SCRIPT}, then re-run."
    fi

    # allocate mode: create and format a fresh volume, as declared in the config.
    info "  Allocating ${MEDIA_SIZE} on ${MEDIA_STORAGE} (mediaStorage=allocate)..."
    pve "pvesm alloc ${MEDIA_STORAGE} ${VMID} vm-${VMID}-media ${MEDIA_SIZE}" >/dev/null \
      && info "  ${GN}✓${CL} Disk allocated: vm-${VMID}-media" \
      || die "pvesm alloc failed — check storage ${MEDIA_STORAGE} exists and has capacity"
    pve "qm set ${VMID} --scsi2 ${MEDIA_STORAGE}:vm-${VMID}-media" >/dev/null \
      && info "  ${GN}✓${CL} Disk attached as scsi2" \
      || die "qm set failed — could not attach disk"

    # A brand-new scsi2 slot means a brand-new virtio-scsi-single controller
    # (a new virtual PCI device) — QEMU/Proxmox cannot hot-add that into a
    # running guest, so the kernel only enumerates it after a reboot.
    info "  Rebooting VM so the kernel sees the new controller..."
    pve "qm reboot ${VMID}" >/dev/null \
      || die "qm reboot failed — reboot ${VMID} manually and re-run"
    wait_for_vm
    remote "test -e ${MEDIA_DEV}" 2>/dev/null \
      || die "Disk attached but still not visible after a reboot — check 'qm config ${VMID}' and the VM console."
    # The volume was just created and must be blank; a filesystem signature
    # here means the device is not the one just allocated — stop, don't format.
    EXISTING_FS=$(remote "sudo blkid -o value -s TYPE ${MEDIA_DEV} 2>/dev/null" || true)
    [[ -z "${EXISTING_FS}" ]] \
      || die "Refusing to format: freshly allocated ${MEDIA_DEV} unexpectedly carries a ${EXISTING_FS} filesystem. Investigate before re-running — nothing has been formatted."
    info "  Formatting the new volume (ext4, label immich-data)..."
    remote "sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}" >/dev/null \
      && info "  ${GN}✓${CL} Disk formatted" \
      || die "mkfs.ext4 failed — format manually on the VM: sudo mkfs.ext4 -L immich-data ${MEDIA_DEV}"
fi

# ── Step 2: Verify the immich-data label (allocate/attached modes) ───────────
wait_for_vm
if [[ "${MEDIA_MODE}" != "share" ]] && ! remote "test -e /dev/disk/by-label/immich-data" 2>/dev/null; then
    die "The disk at scsi2 has no 'immich-data' filesystem label (the VM mounts ${MOUNT_POINT} by that label). Run ${SETUP_SCRIPT} — it inspects the disk and offers a non-destructive relabel or a format, always with confirmation."
fi

# ── Step 3: Mount and verify /var/lib/immich ─────────────────────────────────
if ! remote "mountpoint -q ${MOUNT_POINT}" 2>/dev/null; then
    info "  Reloading systemd and mounting ${MOUNT_POINT}..."
    remote "sudo mkdir -p ${MOUNT_POINT} && sudo systemctl daemon-reload && sudo mount ${MOUNT_POINT}" \
      && info "  ${GN}✓${CL} ${MOUNT_POINT} mounted" \
      || warn "  Mount failed — on a fresh VM this resolves after the first nixos-rebuild (mount unit not defined yet)"
fi

MOUNT_OK=$(remote "mountpoint -q ${MOUNT_POINT} && echo yes || echo no" 2>/dev/null)
if [[ "${MOUNT_OK}" == "yes" ]]; then
    DISK_INFO=$(remote "df -h ${MOUNT_POINT} | tail -1" 2>/dev/null)
    info "  ${GN}✓${CL} ${MOUNT_POINT} is mounted: ${DISK_INFO}"
    # Best-effort ownership fix for re-runs. On first install the immich user
    # does not exist until the first nixos-rebuild; the immich module's
    # tmpfiles rule enforces immich:immich 0700 at activation.
    remote "id immich >/dev/null 2>&1 && sudo chown immich:immich ${MOUNT_POINT} || true" >/dev/null 2>&1 || true
else
    warn "  ${MOUNT_POINT} is not mounted yet. On a fresh VM this is expected —"
    warn "  the mount unit appears with the first nixos-rebuild (update.sh runs next)."
fi

echo ""
info "${GN}✓${CL} immich photostorage service installed"
info "  Immich creates its own layout (upload/, library/, thumbs/, ...) on first start."
