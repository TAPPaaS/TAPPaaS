#!/usr/bin/env bash
#
# cluster:vm — the storage field hook (ADR-020 D4, class `in-place`).
#
# A declared `storage` the guest is not on moves its disks there, live: Proxmox's
# `qm disk move --delete 1` copies a running guest's disk and switches it over
# without a restart. The case it exists for: a firewall or mothership the
# bootstrap built on the boot pool (local-zfs) before the node had a data pool,
# moved onto tanka1 once it has one, so HA replication has a data pool to go to
# (ADR-037 D1).
#
# What moves: every disk on the storage the guest is reported on (its boot disk's
# storage) — scsi/virtio/sata/ide disks and the EFI disk. Not the vTPM state,
# which stays where it was created (Create-TAPPaaS-VM.sh keeps it on local-zfs),
# not the cloud-init drive (regenerated from config), not a CD-ROM.
#
# Only a DECLARED value is applied (fields.json applyOnlyDeclared): the schema
# default never moves a disk, so a guest that never asked for a storage stays
# where it was built.
#
# HA: a replication job writes the guest's volumes to the same storage on the
# failover node, so it cannot carry on across the move. The job is removed first
# (its replica on the failover node with it), and cluster:ha's update makes it
# again afterwards, to the new storage.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-storage.sh <module> --unit <file> [--check] [--force]
#                              [--field storage --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   moved, or already there
#   20  refused: the node has no such storage, or it has too little free space
#   1   error

# The remote `qm`/`pvesr` commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

readonly MGMT="mgmt"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

MODULE=""
UNIT_FILE=""
CHECK=0
DESIRED=""
ACTUAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   : ;;  # nothing to authorize: the move is live
        --field)   shift ;;
        --desired) DESIRED="${2:-}"; shift ;;
        --actual)  ACTUAL="${2:-}"; shift ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-storage.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module> --unit <file> [--check]" >&2; exit 1; }

VMID=""
NODE=""
if [[ -n "${UNIT_FILE}" && -r "${UNIT_FILE}" ]]; then
    DESIRED="$(jq -r '(.fields[] | select(.field == "storage") | .desired) // ""' "${UNIT_FILE}")"
    ACTUAL="$(jq -r  '(.fields[] | select(.field == "storage") | .actual)  // ""' "${UNIT_FILE}")"
    VMID="$(jq -r    '(.actual.vmid) // ""' "${UNIT_FILE}")"
    NODE="$(jq -r    '(.actual.node) // ""' "${UNIT_FILE}")"
fi
if [[ -z "${VMID}" ]]; then
    JSON="$(normalize_module_config < "/home/tappaas/config/${MODULE}.json")"
    VMID="$(get_config_value 'vmid')"
fi
[[ -n "${VMID}" ]] || { error "update-storage.sh: ${MODULE} has no vmid"; exit 1; }
[[ -n "${DESIRED}" ]] || { error "update-storage.sh: no desired storage in the unit"; exit 1; }
if [[ -z "${NODE}" ]]; then
    NODE="$(ssh "${SSH_OPTS[@]}" "root@tappaas1.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --arg id "${VMID}" '.[] | select(.vmid == ($id | tonumber)) | .node' | head -1)" || NODE=""
fi
[[ -n "${NODE}" ]] || { error "update-storage.sh: cannot tell which node VM ${VMID} is on"; exit 1; }
HOST="root@${NODE}.${MGMT}.internal"
on_node() { ssh "${SSH_OPTS[@]}" "${HOST}" "$@"; }

if [[ "${DESIRED}" == "${ACTUAL}" ]]; then
    debug "  storage: already on ${DESIRED}"
    exit 0
fi

# ── the target: on this node, active, holding VM disks, with room ────
# pvesm status: Name Type Status Total Used Available %  (sizes in KiB)
target="$(on_node "pvesm status --enabled 1 --content images 2>/dev/null" | awk -v s="${DESIRED}" 'NR > 1 && $1 == s')" || target=""
if [[ -z "${target}" ]]; then
    error "  storage ${ACTUAL:-?}→${DESIRED}: ${NODE} has no active storage '${DESIRED}' for VM disks"
    error "  Build the pool first (site-manager node storage add ${NODE} ${DESIRED} …), or declare a storage ${NODE} has."
    exit 20
fi
avail_kib="$(awk '{print $6}' <<< "${target}")"

# ── the disks to move ────────────────────────────────────────────────
# "<key>: <storage>:<volume>,…" for every disk on the current storage; the vTPM
# state, a cloud-init drive and a CD-ROM stay.
config="$(on_node "qm config ${VMID}")" || { error "update-storage.sh: qm config ${VMID} failed on ${NODE}"; exit 1; }
mapfile -t disks < <(awk -v s="${ACTUAL}" -F': ' '
    $1 ~ /^(scsi|virtio|sata|ide)[0-9]+$|^efidisk0$/ && index($2, s ":") == 1 &&
    $2 !~ /media=cdrom/ && $2 !~ /cloudinit/ {print $1}' <<< "${config}")
if [[ "${#disks[@]}" -eq 0 ]]; then
    warn "  storage ${ACTUAL:-?}→${DESIRED}: no disk of VM ${VMID} is on '${ACTUAL}' — nothing to move"
    exit 0
fi

# Their size, from the storage itself (the volume's real size, not the config's).
need_bytes=0
plan=()
for d in "${disks[@]}"; do
    vol="$(awk -v k="${d}" -F': ' '$1 == k {split($2, a, ","); print a[1]}' <<< "${config}")"
    bytes="$(on_node "pvesm list ${ACTUAL} --vmid ${VMID} 2>/dev/null" | awk -v v="${vol}" '$1 == v {print $4}')"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    need_bytes=$((need_bytes + bytes))
    plan+=("${d} (${vol}, $((bytes / 1024 ** 3)) GiB)")
done
if [[ "$((avail_kib * 1024))" -lt "$((need_bytes + need_bytes / 10))" ]]; then
    error "  storage ${ACTUAL}→${DESIRED}: $((need_bytes / 1024 ** 3)) GiB to move, ${DESIRED} on ${NODE} has $((avail_kib / 1024 ** 2)) GiB free (10 % kept spare)"
    exit 20
fi

# ── replication ──────────────────────────────────────────────────────
repl_ids="$(on_node "pvesh get /cluster/replication --output-format json" 2>/dev/null \
    | jq -r --arg id "${VMID}" '.[] | select((.guest | tostring) == $id) | .id')" || repl_ids=""

if [[ "${CHECK}" == "1" ]]; then
    info "  storage: would move ${ACTUAL}→${DESIRED} on ${NODE}, live: ${plan[*]}"
    [[ -n "${repl_ids}" ]] && info "  …its replication (${repl_ids//$'\n'/, }) removed first and made again to ${DESIRED} by cluster:ha"
    exit 0
fi

for id in ${repl_ids}; do
    info "  removing replication job ${id} (and its replica) before the move..."
    on_node "pvesr delete ${id}" >/dev/null
done
# The removal is done by the replication runner; the job is gone once its replica is.
if [[ -n "${repl_ids}" ]]; then
    for _ in $(seq 1 60); do
        left="$(on_node "pvesh get /cluster/replication --output-format json" 2>/dev/null \
            | jq -r --arg id "${VMID}" '[.[] | select((.guest | tostring) == $id)] | length')" || left=1
        [[ "${left}" == "0" ]] && break
        sleep 5
    done
    [[ "${left}" == "0" ]] || { error "  the replication of VM ${VMID} was not removed within 5 minutes — not moving"; exit 1; }
fi

for d in "${disks[@]}"; do
    info "  moving ${d} of VM ${VMID} ${ACTUAL}→${DESIRED} (live)..."
    on_node "qm disk move ${VMID} ${d} ${DESIRED} --delete 1" >/dev/null \
        || { error "  qm disk move ${VMID} ${d} ${DESIRED} failed on ${NODE}"; exit 1; }
done
info "  ${GN}✓${CL} VM ${VMID}'s disks are on ${DESIRED}"

# The replication again, now to the new storage.
if [[ -n "${repl_ids}" ]]; then
    info "  making its replication again (cluster:ha)..."
    "${HERE}/../ha/update-service.sh" "${MODULE}" \
        || { error "  cluster:ha did not make the replication again — run: module-manager module update ${MODULE}"; exit 1; }
fi
exit 0
