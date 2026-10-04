#!/usr/bin/env bash
#
# zfs-thin.sh — thin provisioning of a guest's ZFS disks (cluster:vm thinDisk, #773).
#
# A disk on a zfspool storage is a zvol. The pools are added without `sparse`,
# so ZFS gives every zvol a refreservation ≈ volsize: the disk holds its full
# size from day one — and on the HA node too, because replication's
# `zfs send -RpvU` carries the property to the replica. Thin is
# refreservation=none; back to thick is refreservation=auto (ZFS refuses it if
# the pool cannot hold the reservation, which is the right answer).
#
# Which volumes: every disk in `qm config` whose `pvesm path` is a zvol —
# scsi/virtio/sata/ide/efidisk/tpmstate — except the cloud-init drive, which
# Proxmox regenerates. Non-ZFS storage has no refreservation and is skipped.
#
#   zfs_thin_node_script            the node-side script, on stdout
#   zfs_thin_remote <node> <vmid> <report|thin|thick>
#                                   runs it on root@<node>.mgmt.internal
#
# The node script prints, for `report`: "true" (every zvol thin), "false" (at
# least one is not), or nothing (the guest has no zvol — not observable). For
# `thin`/`thick` it prints one line per volume it changed. Create-TAPPaaS-VM.sh
# runs on the node itself and carries its own copy of the volume loop (node-side
# scripts are self-contained); keep the two in step.

zfs_thin_node_script() {
    cat <<'NODE'
set -euo pipefail
vmid="$1"; action="$2"
vols=()
while IFS= read -r vol; do
    case "${vol}" in *cloudinit*) continue ;; esac
    zpath="$(pvesm path "${vol}" 2>/dev/null)" || continue
    [[ "${zpath}" == /dev/zvol/* ]] || continue
    vols+=("${zpath#/dev/zvol/}")
done < <(qm config "${vmid}" | sed -n -E 's/^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+: ([^,]+).*/\2/p')
[[ "${#vols[@]}" -gt 0 ]] || exit 0
case "${action}" in
    report)
        for v in "${vols[@]}"; do
            [[ "$(zfs get -H -o value refreservation "${v}")" == "none" ]] || { echo false; exit 0; }
        done
        echo true ;;
    thin)
        for v in "${vols[@]}"; do zfs set refreservation=none "${v}"; echo "${v}"; done ;;
    thick)
        for v in "${vols[@]}"; do zfs set refreservation=auto "${v}"; echo "${v}"; done ;;
    *) echo "zfs-thin: unknown action '${action}'" >&2; exit 2 ;;
esac
NODE
}

zfs_thin_remote() {
    local node="$1" vmid="$2" action="$3"
    zfs_thin_node_script | ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" bash -s -- "${vmid}" "${action}"
}
