#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - automatic disk growth (#100)
#
# Grows a guest's disk before it fills. Run by update-service.sh ahead of the
# drift converge, so every module update checks its own disk — a VM's scsi0, or
# a container's rootfs (cluster:lxc runs it too, #901):
#
#   1. measure  — how full the guest's / is (df; a container through
#                 `pct exec` on its node), and the disk's real size
#   2. decide   — at or over the threshold: +growPercent, at least minGrowGB,
#                 capped at the module's diskSizeMax
#   3. room     — the disk's pool on the guest's node, and on its HA replica
#                 node, must hold the increase and stay under poolCeiling
#   4. act      — room: write the new diskSize into the module config; the
#                 converge that follows grows the disk (grow-only, no reboot)
#                 no room: a DEFERRED: line, nothing changes
#
# This step only changes the DESIRED size, as an operator's `module modify --set
# diskSize=` would; the growing is the converge's, so check, apply, adopt and
# rollback behave as for any other change. A rollback restores the config and
# the disk to the snapshot's size, and the next run grows it again.
#
# Settings: site.json diskAutoGrow {enabled, threshold, growPercent, minGrowGB,
# poolCeiling}; per module diskAutoGrow (false = never) and diskSizeMax.
# TAPPAAS_AUTOGROW_THRESHOLD / TAPPAAS_AUTOGROW_POOL_CEILING override the site's
# values for one run (check-disk-threshold.sh, tests).
#
# Usage: auto-grow.sh [--check] <module>
# Exit: 0 always unless the module config is missing — a guest that cannot be
#       measured is skipped with a warning, never a failed update.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly MGMT="mgmt"
readonly RESIZE_LOG="/home/tappaas/logs/disk-resize.log"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh disable=SC1091
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"
# shellcheck source=../../lib/disk-grow-lib.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/disk-grow-lib.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

CHECK=0
MODULE=""
for _a in "$@"; do
    case "${_a}" in
        --check) CHECK=1 ;;
        -*)      echo "auto-grow.sh: unknown option '${_a}'" >&2; exit 1 ;;
        *)       MODULE="${_a}" ;;
    esac
done
[[ -n "${MODULE}" ]] || { echo "Usage: $0 [--check] <module>" >&2; exit 1; }
CFG="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${CFG}" ]] || { error "auto-grow: no config for ${MODULE}"; exit 1; }

skip() { debug "  auto-grow ${MODULE}: $*"; exit 0; }

# ── settings ─────────────────────────────────────────────────────────
site="${CONFIG_DIR}/site.json"
sset() { jq -r --arg k "$1" --arg d "$2" '(.diskAutoGrow // {})[$k] | if . == null then $d else tostring end' "${site}" 2>/dev/null || echo "$2"; }
[[ "$(sset enabled true)" == "false" ]] && skip "off for the site (site.json diskAutoGrow.enabled)"
THRESHOLD="${TAPPAAS_AUTOGROW_THRESHOLD:-$(sset threshold 80)}"
GROWPCT="$(sset growPercent 50)"
MINGB="$(sset minGrowGB 5)"
CEILING="${TAPPAAS_AUTOGROW_POOL_CEILING:-$(sset poolCeiling 80)}"

resolved="$(module-manager module resolve "${MODULE}" --json 2>/dev/null)" || skip "could not resolve the module"
field() { jq -r --arg f "$1" '(.fields[$f].value) // empty | tostring' <<< "${resolved}"; }
# The two policy fields straight from the config (either Pattern): nothing on
# the cluster reports them, and their defaults are "on" and "no cap".
# (No `//` here: jq's alternative operator treats false as missing.)
cfgval() { jq -r --arg f "$1" '[.. | objects | select(has($f)) | .[$f]][0] | if . == null then empty else tostring end' "${CFG}" 2>/dev/null; }
[[ "$(cfgval diskAutoGrow)" == "false" ]] && skip "off for this module (diskAutoGrow: false)"
case "$(field status)" in external|archived) skip "status $(field status)" ;; esac
ostype="$(field ostype)"
VMID="$(field vmid)"
[[ -n "${VMID}" ]] || skip "no vmid"
VMNAME="$(field vmname)"; VMNAME="${VMNAME:-${MODULE}}"
ZONE0="$(field zone0)"; ZONE0="${ZONE0:-mgmt}"
MAXGB=0
_max="$(cfgval diskSizeMax)"
[[ -n "${_max}" ]] && MAXGB="$(dg_size_gb "${_max}")"
HANODE="$(cfgval HANode)"

# ── measure ──────────────────────────────────────────────────────────
node="" status="" gtype=""
for n in $(get_all_node_hostnames); do
    row="$(ssh -n "${SSH_OPTS[@]}" "root@${n}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" '.[] | select(.vmid == $id and (.type == "qemu" or .type == "lxc")) | "\(.node) \(.status) \(.type)"' 2>/dev/null)" || true
    [[ -n "${row}" ]] && { read -r node status gtype <<< "${row}"; break; }
done
[[ -n "${node}" ]] || skip "guest ${VMID} not found on the cluster"
[[ "${status}" == "running" ]] || skip "guest ${VMID} is ${status}"
# A container's ostype names its distribution; a VM's must be Linux (l26).
[[ "${gtype}" == lxc || -z "${ostype}" || "${ostype}" == l26 ]] || skip "not a Linux guest (ostype ${ostype})"

# The disk: a VM's scsi0, a container's rootfs. Its use: df over SSH in a VM,
# through `pct exec` on the node for a container (which needs no SSH of its own).
DF="df -P / | awk 'NR==2 {sub(\"%\",\"\",\$5); print \$5}'"
if [[ "${gtype}" == lxc ]]; then
    # shellcheck disable=SC2029
    disk="$(ssh -n "${SSH_OPTS[@]}" "root@${node}.${MGMT}.internal" "pct config ${VMID}" 2>/dev/null | sed -n 's/^rootfs: //p')"
    [[ -n "${disk}" ]] || skip "no rootfs on CT ${VMID}"
    # shellcheck disable=SC2029
    used="$(ssh -n "${SSH_OPTS[@]}" "root@${node}.${MGMT}.internal" "pct exec ${VMID} -- sh -c $(printf '%q' "${DF}")" 2>/dev/null)" || used=""
    where="pct exec ${VMID} on ${node}"
else
    # shellcheck disable=SC2029
    disk="$(ssh -n "${SSH_OPTS[@]}" "root@${node}.${MGMT}.internal" "qm config ${VMID}" 2>/dev/null | sed -n 's/^scsi0: //p')"
    [[ -n "${disk}" ]] || skip "no scsi0 disk on VM ${VMID}"
    used="$(ssh -n "${SSH_OPTS[@]}" "tappaas@${VMNAME}.${ZONE0}.internal" "${DF}" 2>/dev/null)" || used=""
    where="ssh ${VMNAME}.${ZONE0}.internal"
fi
storage="${disk%%:*}"
size="$(sed -n 's/.*size=\([0-9]*[KMGT]\).*/\1/p' <<< "${disk}")"
[[ -n "${size}" ]] || skip "cannot read the size of ${disk}"
CURGB="$(dg_size_gb "${size}")"

if ! [[ "${used}" =~ ^[0-9]+$ ]]; then
    warn "  auto-grow ${MODULE}: cannot read disk use in the guest (${where}) — not checked"
    exit 0
fi

# ── decide ───────────────────────────────────────────────────────────
rc=0
NEWGB="$(dg_decide "${used}" "${CURGB}" "${THRESHOLD}" "${GROWPCT}" "${MINGB}" "${MAXGB}")" || rc=$?
case ${rc} in
    1) skip "/ ${used}% < ${THRESHOLD}% (${CURGB}G)" ;;
    2) warn "DEFERRED: ${MODULE} disk / is ${used}% full and already at diskSizeMax (${CURGB}G) — free space in the guest or raise diskSizeMax"
       exit 0 ;;
esac
INC=$(( NEWGB - CURGB ))

# ── room ─────────────────────────────────────────────────────────────
nodes=("${node}")
[[ -n "${HANODE}" && "${HANODE}" != "${node}" ]] && nodes+=("${HANODE}")
for n in "${nodes[@]}"; do
    # shellcheck disable=SC2029
    line="$(ssh -n "${SSH_OPTS[@]}" "root@${n}.${MGMT}.internal" "pvesm status --storage ${storage}" 2>/dev/null | awk 'NR==2')"
    read -r _ _ _ total pused avail _ <<< "${line}"
    if ! [[ "${total:-}" =~ ^[0-9]+$ && "${pused:-}" =~ ^[0-9]+$ && "${avail:-}" =~ ^[0-9]+$ ]]; then
        warn "DEFERRED: ${MODULE} disk / is ${used}% full — cannot read pool ${storage} on ${n}, not growing"
        exit 0
    fi
    after=0
    after="$(dg_pool_room "${total}" "${pused}" "${avail}" "${INC}" "${CEILING}")" || {
        warn "DEFERRED: ${MODULE} disk / is ${used}% full — pool ${storage} on ${n} has no room for +${INC}G (would be ${after}% used, ceiling ${CEILING}%)"
        exit 0
    }
done

# ── act ──────────────────────────────────────────────────────────────
msg="diskSize ${CURGB}G→${NEWGB}G: / is ${used}% full (threshold ${THRESHOLD}%), pool ${storage} has room"
if [[ "${CHECK}" == "1" ]]; then
    info "  auto-grow ${MODULE}: would grow — ${msg}"
    exit 0
fi
jq_module_write "${MODULE}" '.diskSize = $v' --arg v "${NEWGB}G" \
    || { warn "  auto-grow ${MODULE}: could not write diskSize into config — not growing"; exit 0; }
warn "  auto-grow ${MODULE}: ${msg}"
mkdir -p "$(dirname "${RESIZE_LOG}")"
echo "$(date '+%Y-%m-%d %H:%M:%S') - ${MODULE}: ${msg}" >> "${RESIZE_LOG}"
exit 0
