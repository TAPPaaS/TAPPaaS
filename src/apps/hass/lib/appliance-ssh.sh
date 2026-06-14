#!/usr/bin/env bash
#
# TAPPaaS hass — Appliance SSH provisioning (module-local; std core untouched)
#
# HAOS is a sealed appliance: it ignores cloud-init, so the standard engine's
# `qm set --sshkey` (native) path cannot inject the tappaas key. HAOS only
# enables host SSH (root@22222, key-only) when it finds an `authorized_keys` on a
# partition LABELLED 'CONFIG' at boot. This service provisions that out-of-band,
# AFTER the std engine has created+started the VM, entirely from the module:
#   1. Build a small FAT image labelled CONFIG holding authorized_keys =
#      the canonical tappaas-cicd.pub (already present on every node), attach it.
#   2. Enable the QEMU guest agent with freeze-fs-on-backup (FS-consistent
#      backups; the std engine sets only `enabled=1`).
#   3. Full stop/start: HAOS reads the CONFIG label only at boot, and the agent
#      freeze-fs channel attaches on a cold start (not a reboot).
#
# All node operations go over `ssh root@<node>` + `qm` — the SAME channel the
# hass:config service already uses. No modification to the shared deployment
# engine; this keeps the appliance special-case inside the appliance module.
# Idempotent: the disk build is skipped if a CONFIG key disk is already attached.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-hass}"
check_json "/home/tappaas/config/${MODULE}.json" || exit 1

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
STORAGE="$(get_config_value 'storage' 'local-zfs')"
NODE_FQDN="${NODE}.mgmt.internal"
PUBKEY="/root/tappaas/tappaas-cicd.pub"   # canonical key, already on every node
SERIAL="tappaas-config-ssh"               # tags the disk for idempotency
SCSI_IDX=1                                # scsi0 = HAOS OS disk; CONFIG on scsi1

[[ -n "${VMID}" ]] || die "appliance-ssh: ${MODULE} has no vmid"

info "hass appliance-ssh: provisioning root@22222 + QGA freeze-fs for ${BL}${VMNAME}${CL} (VMID ${VMID}) on ${NODE}"

# ── Step 1: build + attach the CONFIG-labelled key disk (idempotent) ─────────
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "qm config ${VMID} 2>/dev/null | grep -q 'serial=${SERIAL}'"; then
    info "  ${GN}✓${CL} CONFIG key disk already attached — skipping disk build"
else
    info "  Building + attaching CONFIG key disk (authorized_keys = tappaas-cicd.pub)..."
    # Remote script runs on the node (root). Args injected via bash -s; the body
    # is a quoted heredoc so nothing expands on the cicd side.
    VOLID="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "bash -s -- '${VMID}' '${STORAGE}' '${PUBKEY}'" <<'REMOTE'
set -e
VMID="$1"; STORAGE="$2"; PUBKEY="$3"
[ -f "$PUBKEY" ] || { echo "MISSING_PUBKEY"; exit 3; }
img="$(mktemp /tmp/tappaas-config-ssh-"$VMID".XXXXXX.raw)"
mnt="$(mktemp -d)"
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; rm -f "$img"' EXIT
truncate -s 32M "$img"
mkfs.vfat -n CONFIG "$img" >/dev/null
mount -o loop "$img" "$mnt"
tr -d '\r' < "$PUBKEY" > "$mnt/authorized_keys"   # LF/ASCII — HAOS is strict
sync
umount "$mnt"
out="$(qm importdisk "$VMID" "$img" "$STORAGE" --format raw 2>&1)"
vol="$(echo "$out" | grep -oE "$STORAGE:[A-Za-z0-9._/-]*vm-$VMID-disk-[0-9]+" | tail -1)"
[ -n "$vol" ] || vol="$(echo "$out" | grep -oE "'[^']*vm-$VMID-disk-[0-9]+'" | tr -d "'" | tail -1)"
[ -n "$vol" ] || { echo "NO_VOLID"; exit 4; }
echo "$vol"
REMOTE
)" || die "appliance-ssh: failed to build/import CONFIG disk on ${NODE}"

    case "${VOLID}" in
        ""|MISSING_PUBKEY|NO_VOLID)
            die "appliance-ssh: could not determine CONFIG disk volid (result: '${VOLID:-empty}')" ;;
    esac
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "qm set ${VMID} --scsi${SCSI_IDX} '${VOLID},serial=${SERIAL}'" >/dev/null \
        || die "appliance-ssh: failed to attach CONFIG disk (${VOLID})"
    info "  ${GN}✓${CL} CONFIG disk attached (scsi${SCSI_IDX}, serial=${SERIAL})"
fi

# ── Step 2: QGA freeze-fs (FS-consistent backups) ────────────────────────────
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
    "qm set ${VMID} --agent enabled=1,freeze-fs-on-backup=1" >/dev/null \
    || warn "appliance-ssh: could not set agent freeze-fs (continuing)"

# ── Step 3: GRACEFUL stop/start (HAOS reads CONFIG at boot; agent channel attaches) ─
# Use `qm shutdown` (ACPI/guest-agent graceful) — NOT `qm stop` (hard power-off).
# A hard power-off of HAOS corrupts the docker/supervisor network + ext4 (the same
# failure mode as the 2026-06-13 incident; cf. HA supervisor issue #4354 "no route
# to host 172.30.32.2"). A clean shutdown lets HAOS flush before the CONFIG disk is
# re-read on the next boot.
info "  Graceful stop/start so HAOS flushes cleanly + reads the CONFIG disk on boot..."
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "qm shutdown ${VMID} --timeout 150" >/dev/null 2>&1; then
    warn "appliance-ssh: graceful shutdown timed out (150s) — verify HAOS health before retrying (do NOT hard-stop)"
fi
for _i in $(seq 1 30); do
    _st="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "qm status ${VMID} 2>/dev/null" | awk '{print $2}')"
    [[ "${_st}" == "stopped" ]] && break
    sleep 2
done
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
    "qm start ${VMID}" >/dev/null || die "appliance-ssh: failed to start ${VMID}"

# Wait until the guest agent reports a network interface after the cold boot —
# exactly what the downstream config step needs (HA-IP detection), so no arbitrary
# settle sleep is required.
info "  Waiting for guest agent + network after restart (HAOS cold boot)..."
_agent_up=0
for _i in $(seq 1 60); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
            "qm agent ${VMID} network-get-interfaces 2>/dev/null" 2>/dev/null \
            | grep -q '"ip-address"'; then
        _agent_up=1; break
    fi
    sleep 5
done
[[ "${_agent_up}" -eq 1 ]] && info "  ${GN}✓${CL} guest agent + network back after restart" \
    || warn "appliance-ssh: guest agent/network not ready 300s after restart (downstream may retry)"

info "  ${GN}✓${CL} ${VMNAME}: host SSH root@22222 active + QGA freeze-fs on"
