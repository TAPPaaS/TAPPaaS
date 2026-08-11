#!/usr/bin/env bash
#
# TAPPaaS Cluster — stale cloud-init volume sweep (cloudinit-orphans.sh)
#
# Finds and frees cloud-init volumes left behind on a node after an HA recovery,
# which otherwise block the VM from ever migrating back (issue #146,
# https://bugzilla.proxmox.com/show_bug.cgi?id=7608).
#
# Why these orphans exist
# -----------------------
# Cloud-init drives are attached as media=cdrom, and QemuConfig's
# get_replicatable_volumes() returns early on cdrom volumes — so they are never
# covered by a replication job. Migration therefore has to full-send them as a
# local disk, and does so with allow_rename=0 (the name is VMID-derived and
# cannot take a -1 suffix). A pre-existing volume at the target is thus a hard
# error that aborts the WHOLE migration in phase 1, and the HA CRM then retries
# every ~10s indefinitely — freezing/thawing the guest filesystem on every
# attempt.
#
# A completed migration cleans up after itself (phase3_cleanup → vdisk_free).
# The orphan only survives a transition that is NOT a completed migration:
# an HA recovery after fence/crash/ungraceful shutdown, or a migration that
# aborted partway.
#
# Freeing the orphan is always safe: cloud-init payload is fully derived from
# the VM config in /etc/pve (cluster-wide), and the instance-id is
# sha1_hex(user_data . network_data) — deterministic, not random. PVE
# regenerates the volume on VM start, producing identical content and the same
# instance-id, so the guest never sees a new instance. A stale orphan is in fact
# the more dangerous artefact: it can carry outdated config with a DIFFERENT
# instance-id, which would make cloud-init re-run every per-instance module.
#
# Usage:
#   cloudinit-orphans.sh [--dry-run|--execute] [--quiet] [node ...]
#
#   --dry-run   Report orphans without freeing them (default)
#   --execute   Free the orphans found
#   --quiet     Only emit output when something was found (for timers)
#   node ...    Limit the sweep to these nodes (default: all cluster nodes)
#
# Exit codes:
#   0  no orphans found, or orphans freed successfully (--execute)
#   1  a fatal error (unreachable node, bad arguments)
#   2  orphans found but not freed (--dry-run) — useful as a check in CI/tests
#
# Examples:
#   cloudinit-orphans.sh                      # report across the whole cluster
#   cloudinit-orphans.sh --execute tappaas1   # clean one node after it returns
#

set -euo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

readonly SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# A volid we are willing to hand to a remote `pvesm free`. PVE storage IDs are
# [a-z][a-z0-9\-_.]* and the VMID is numeric, so anything outside this shape did
# not come from our probe and must not be interpolated into a remote command.
readonly VOLID_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]*:vm-[0-9]+-cloudinit$'

DRY_RUN=1
QUIET=0
NODES=()

usage() {
    cat <<'EOF'
Usage: cloudinit-orphans.sh [--dry-run|--execute] [--quiet] [node ...]

  --dry-run   Report orphaned cloud-init volumes without freeing them (default)
  --execute   Free the orphans found
  --quiet     Only produce output when orphans are found
  node ...    Limit the sweep to these nodes (default: all cluster nodes)

Exit: 0 clean/fixed, 1 error, 2 orphans found in dry-run.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --execute) DRY_RUN=0; shift ;;
        --quiet)   QUIET=1; shift ;;
        --help|-h) usage; exit 0 ;;
        -*)        usage; die "Unknown option: $1" ;;
        *)         NODES+=("$1"); shift ;;
    esac
done

if [[ ${#NODES[@]} -eq 0 ]]; then
    mapfile -t NODES < <(get_all_node_hostnames)
fi
[[ ${#NODES[@]} -gt 0 ]] || die "No cluster nodes resolved"

say() { [[ "${QUIET}" -eq 1 ]] || info "$@"; }

###############################################################################
# Remote probe
###############################################################################
# Classifies every cloud-init volume on the node's own non-shared storages.
# Emits TSV: <class> <volid> <vmid> <owner-node>
#
#   inuse    the VM's config lives on this node — leave alone
#   orphan   the VM's config lives on ANOTHER node — safe to free
#   locked   config is on another node but carries a lock: (migration may be
#            in flight, and its freshly-received copy would look like an
#            orphan) — skip this round, the sweep is idempotent
#   unowned  no config anywhere in the cluster — report only, never delete:
#            this is a different orphan class (e.g. a VM pending restore)
#
# Storages are filtered to those actually available on this node; .shared
# storages are excluded because there a single copy is visible cluster-wide and
# freeing it would destroy the live volume.
probe_node() {
    local node="$1"
    # shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
    ssh ${SSH_OPTS} "root@${node}.mgmt.internal" 'bash -s' <<'REMOTE'
set -uo pipefail
me="$(hostname -s)"

stores=$(pvesh get /storage --output-format json 2>/dev/null | jq -r --arg me "$me" '
    .[]
    | select((.shared // 0) != 1)
    | select((.content // "") | test("images"))
    | select((.nodes // "") == "" or ((.nodes | split(",")) | index($me)))
    | .storage')

for store in $stores; do
    pvesm list "$store" 2>/dev/null | awk 'NR>1 {print $1}' | while read -r volid; do
        case "$volid" in
            *:vm-*-cloudinit) ;;
            *) continue ;;
        esac
        vmid=${volid##*:vm-}; vmid=${vmid%-cloudinit}
        case "$vmid" in ''|*[!0-9]*) continue ;; esac

        conf=$(ls /etc/pve/nodes/*/qemu-server/"${vmid}".conf 2>/dev/null | head -1)
        if [ -z "$conf" ]; then
            printf 'unowned\t%s\t%s\t-\n' "$volid" "$vmid"
            continue
        fi
        owner=$(basename "$(dirname "$(dirname "$conf")")")
        if [ "$owner" = "$me" ]; then
            printf 'inuse\t%s\t%s\t%s\n' "$volid" "$vmid" "$owner"
        elif grep -q '^lock:' "$conf" 2>/dev/null; then
            printf 'locked\t%s\t%s\t%s\n' "$volid" "$vmid" "$owner"
        else
            printf 'orphan\t%s\t%s\t%s\n' "$volid" "$vmid" "$owner"
        fi
    done
done
REMOTE
}

###############################################################################
# Sweep
###############################################################################
total_orphans=0
total_freed=0
failed=0

say "${BOLD}TAPPaaS cloud-init orphan sweep${CL}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    say "  Mode: ${YW}DRY-RUN${CL} (report only)"
else
    say "  Mode: ${GN}EXECUTE${CL}"
fi

for node in "${NODES[@]}"; do
    say ""
    say "${BOLD}${node}${CL}"

    if ! out=$(probe_node "${node}" 2>/dev/null); then
        warn "  Cannot reach ${node} — skipped"
        failed=1
        continue
    fi

    found_here=0
    while IFS=$'\t' read -r class volid vmid owner; do
        [[ -n "${class:-}" ]] || continue
        case "${class}" in
            orphan)
                found_here=1
                total_orphans=$((total_orphans + 1))
                if [[ ! "${volid}" =~ ${VOLID_RE} ]]; then
                    error "  Refusing to act on unexpected volume id: ${volid}"
                    failed=1
                    continue
                fi
                if [[ "${DRY_RUN}" -eq 1 ]]; then
                    warn "  ORPHAN  ${volid} (VM ${vmid} lives on ${owner}) — would free"
                else
                    # SC2086: SSH_OPTS is intentionally word-split.
                    # SC2029: ${volid} expanding client-side is intended — it is
                    # validated against VOLID_RE immediately above.
                    # shellcheck disable=SC2086,SC2029
                    if ssh ${SSH_OPTS} "root@${node}.mgmt.internal" \
                           "pvesm free ${volid}" >/dev/null 2>&1; then
                        info "  ${GN}✓${CL} freed ${volid} (VM ${vmid} lives on ${owner})"
                        total_freed=$((total_freed + 1))
                    else
                        error "  Failed to free ${volid} on ${node}"
                        failed=1
                    fi
                fi
                ;;
            locked)
                found_here=1
                warn "  SKIP    ${volid} — VM ${vmid} is locked (migration in flight?); re-run later"
                ;;
            unowned)
                found_here=1
                warn "  UNOWNED ${volid} — no VM ${vmid} config anywhere in the cluster."
                warn "          Not touching it; remove by hand if the VM is really gone:"
                warn "            ssh root@${node}.mgmt.internal pvesm free ${volid}"
                ;;
            inuse)
                debug "  ok      ${volid} (VM ${vmid} is on this node)"
                ;;
        esac
    done <<< "${out}"

    [[ "${found_here}" -eq 1 ]] || say "  ${GN}✓${CL} no stale cloud-init volumes"
done

###############################################################################
# Result
###############################################################################
say ""
if [[ "${total_orphans}" -eq 0 ]]; then
    say "${GN}✓${CL} No orphaned cloud-init volumes found"
    [[ "${failed}" -eq 0 ]] || exit 1
    exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    warn "${total_orphans} orphaned cloud-init volume(s) found — re-run with --execute to free them"
    exit 2
fi

info "${GN}✓${CL} Freed ${total_freed}/${total_orphans} orphaned cloud-init volume(s)"
[[ "${failed}" -eq 0 ]] || exit 1
exit 0
