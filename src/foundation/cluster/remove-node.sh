#!/usr/bin/env bash
#
# TAPPaaS Cluster Node Removal (remove-node.sh) — #417
#
# Takes a node out of the Proxmox cluster for good: workload check → (erase) →
# power off → pvecm delnode → its /etc/pve/nodes directory, its place in the
# storage entries and in the cluster's known_hosts. `site-manager node delete`
# runs this, then drops the node from site.json and archives its pvehost module.
#
# Usage:
#   remove-node.sh [--dry-run|--execute] [--shutdown|--erase|--lost] <node>
#
#   --dry-run    the plan and every blocker; changes nothing (default)
#   --execute    carry it out, after typing the node name
#   --shutdown   power the node off first (Proxmox requires it to be off before
#                pvecm delnode); without it a node that still answers is refused
#   --erase      before powering off: destroy every ZFS pool and wipe its disks,
#                wipe the boot disk's partitions and partition table, and delete
#                its boot entry — the machine keeps nothing. Type ERASE as well.
#   --lost       the node is DOWN for good (RESTORE.md §3.1): the guests the
#                cluster still places on it are lost with it — their configs are
#                saved on the mothership, then go with the node; replication jobs
#                to or from it are removed; HA rules naming it stay (a replacement
#                under the same name inherits them). Refused for a node that answers.
#
# Refused while the node holds anything: a guest (VM or container), a
# replication job from or to it, an HA rule naming it, the site's PBS. Each is
# listed with what moves it.
#
# Exit: 0 removed (or a clean dry-run) · 1 refused or failed · 2 usage
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/reboot-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/reboot-node-lib.sh"
# shellcheck source=lib/remove-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/remove-node-lib.sh"

DRY_RUN=1; SHUTDOWN=0; ERASE=0; LOST=0; NODE=""
CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
OFF_WAIT="${RMN_OFF_WAIT:-300}"

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --execute)  DRY_RUN=0; shift ;;
        --shutdown) SHUTDOWN=1; shift ;;
        --erase)    ERASE=1; SHUTDOWN=1; shift ;;
        --lost)     LOST=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         error "Unknown option: $1"; exit 2 ;;
        *)          NODE="$1"; shift ;;
    esac
done
[[ -n "$NODE" ]] || { usage; exit 2; }

echo
info "${BOLD}TAPPaaS remove-node — ${NODE}${CL}"
if [[ "$DRY_RUN" -eq 1 ]]; then info "  Mode: ${YW}DRY-RUN${CL} (no changes)"
elif [[ "$ERASE" -eq 1 ]]; then info "  Mode: ${RD}EXECUTE + ERASE${CL}"
else info "  Mode: ${RD}EXECUTE${CL}"; fi
echo

# ── Step 1: a peer to work from ─────────────────────────────────────────
PEER=""
while IFS= read -r n; do
    [[ -n "$n" && "$n" != "$NODE" ]] || continue
    rn_node_ssh "$n" true 2>/dev/null && { PEER="$n"; break; }
done < <(get_all_node_hostnames)
[[ -n "$PEER" ]] || die "no other node answers — cannot remove ${NODE} from a cluster nobody else can speak for"
peer() { rn_node_ssh "$PEER" "$@"; }
info "${BOLD}Step 1: State${CL} (asking ${PEER})"

MEMBER=0
# corosync.conf, not `pvecm nodes`: that lists only the members that are up,
# and a lost node is exactly the one that is not.
peer "grep -qE '^[[:space:]]*name:[[:space:]]*${NODE}[[:space:]]*\$' /etc/pve/corosync.conf" 2>/dev/null && MEMBER=1
ONLINE=0
rn_node_ssh "$NODE" true 2>/dev/null && ONLINE=1
info "  cluster member: $([[ $MEMBER -eq 1 ]] && echo yes || echo "no (already evicted)")"
info "  answers ssh:    $([[ $ONLINE -eq 1 ]] && echo yes || echo no)"
[[ "$ERASE" -eq 1 && "$ONLINE" -eq 0 ]] && die "--erase needs the node running — ${NODE} does not answer"
[[ "$LOST" -eq 1 && "$ONLINE" -eq 1 ]] && die "--lost is for a node that is down — ${NODE} answers: move what it holds, then remove it with --shutdown"
[[ "$LOST" -eq 1 && "$ERASE" -eq 1 ]] && die "--lost and --erase exclude each other"

# ── Step 2: what it still holds ─────────────────────────────────────────
echo
info "${BOLD}Step 2: What ${NODE} still holds${CL}"
BLOCKERS=0
block() { error "  ✗ $1"; BLOCKERS=$((BLOCKERS + 1)); }

RES="$(peer "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)" || die "cannot list the cluster's guests"
LOST_GUESTS=()
while read -r vmid name type; do
    [[ -n "$vmid" ]] || continue
    m="$(rmn_module_of_vmid "$vmid" "$CONFIG_DIR")"
    if [[ "$LOST" -eq 1 ]]; then
        LOST_GUESTS+=("${type} ${vmid}")
        warn "  ${type} ${vmid} (${name}) is lost with the node — restore it from backup: backup-manager restore restore ${m:-<module>} --node <node> (RESTORE.md §3.3)"
    elif [[ -n "$m" ]]; then
        block "${type} ${vmid} (${name}) runs here — move it: module-manager modify ${m} --set node=<other>, then module-manager migrate ${m}"
    else
        block "${type} ${vmid} (${name}) runs here and is no module's — migrate or remove it by hand"
    fi
done < <(rmn_guests_on "$NODE" "$RES")
if [[ "$ONLINE" -eq 0 && "$LOST" -eq 0 && "$BLOCKERS" -gt 0 ]]; then
    error "  ${NODE} is down: if it is gone for good, --lost removes it and reports what to restore"
fi

REPL="$(peer "pvesh get /cluster/replication --output-format json" 2>/dev/null)" || REPL='[]'
mapfile -t REPL_JOBS < <(rmn_replication_touching "$NODE" "$REPL")
for j in "${REPL_JOBS[@]}"; do
    [[ -n "$j" ]] || continue
    if [[ "$LOST" -eq 1 ]]; then warn "  replication job ${j} — removed with the node; site-manager update re-folds HA after the restore"
    else block "replication job ${j} — change the module's HANode, then site-manager update re-folds it"; fi
done

RULES="$(peer "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null)" || RULES='[]'
while read -r rule nodes; do
    [[ -n "$rule" ]] || continue
    if [[ "$LOST" -eq 1 ]]; then warn "  HA rule ${rule} names it (${nodes}) — kept: a replacement under the same name inherits it"
    else block "HA rule ${rule} names it (${nodes}) — change that module's node/HANode"; fi
done < <(rmn_ha_rules_naming "$NODE" "$RULES")

if [[ -f "${CONFIG_DIR}/backup.json" ]] && rmn_pbs_on "$NODE" "$(cat "${CONFIG_DIR}/backup.json")"; then
    if [[ "$LOST" -eq 1 ]]; then warn "  the site's PBS ran here — its backups are gone with it unless a copy exists elsewhere (RESTORE.md §6)"
    else block "the site's PBS (backup datastore) runs here — move it first (backup-manager placement)"; fi
fi
[[ "$BLOCKERS" -eq 0 ]] && info "  ${GN}✓${CL} nothing — no guest, replication job, HA rule or PBS"

# ── Step 3: the plan ────────────────────────────────────────────────────
STOR="$(peer "pvesh get /storage --output-format json" 2>/dev/null)" || STOR='[]'
mapfile -t STOR_CHANGES < <(rmn_storage_changes "$NODE" "$STOR")
echo
info "${BOLD}Step 3: Plan${CL}"
if [[ "$ERASE" -eq 1 ]]; then
    info "  ${RD}ERASE${CL} ${NODE}: destroy its ZFS pools and wipe their disks; wipe the boot disk's partitions"
    info "        and partition table; delete its boot entry — nothing on the machine survives"
fi
if [[ "$ONLINE" -eq 1 ]]; then
    if [[ "$SHUTDOWN" -eq 1 ]]; then info "  power ${NODE} off and wait until it is gone (≤ ${OFF_WAIT}s)"
    else block "${NODE} is running — Proxmox removes a node only once it is off: add --shutdown (or power it off)"; fi
fi
if [[ "${#LOST_GUESTS[@]}" -gt 0 ]]; then
    info "  save the configs of ${#LOST_GUESTS[@]} lost guest(s) to ${LOST_DIR:=/home/tappaas/logs/removed-${NODE}-$(date +%Y%m%d-%H%M%S)}"
fi
for j in "${REPL_JOBS[@]}"; do [[ -n "$j" && "$LOST" -eq 1 ]] && info "  remove replication job ${j%% *}"; done
[[ "$MEMBER" -eq 1 ]] && info "  pvecm delnode ${NODE} (from ${PEER})"
info "  remove /etc/pve/nodes/${NODE} and its entries in the cluster's known_hosts"
for c in "${STOR_CHANGES[@]}"; do
    case "$c" in
        set*)    info "  storage ${c#set }  (${NODE} taken out)" ;;
        remove*) info "  storage ${c#remove }: only ${NODE} — the entry is removed (configuration only)" ;;
    esac
done

if [[ "$BLOCKERS" -gt 0 ]]; then
    echo
    error "${BLOCKERS} thing(s) stop the removal — nothing was changed."
    exit 1
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    info "${YW}DRY-RUN complete — no changes made.${CL}"
    _how=""; [[ $SHUTDOWN -eq 1 ]] && _how=" --shutdown"; [[ $ERASE -eq 1 ]] && _how=" --erase"; [[ $LOST -eq 1 ]] && _how=" --lost"
    info "  To execute: site-manager node delete ${NODE} --apply${_how}"
    exit 0
fi

# ── Step 4: confirmation ────────────────────────────────────────────────
echo
warn "${BOLD}You are about to remove ${NODE} from the cluster.${CL}"
read -rp "  Type the node name to confirm (or Ctrl-C to abort): " CONFIRM
[[ "$CONFIRM" == "$NODE" ]] || die "Confirmation mismatch — nothing was changed"
if [[ "$ERASE" -eq 1 ]]; then
    warn "${BOLD}${RD}--erase: every disk of ${NODE} — boot disk included — is wiped. This cannot be undone.${CL}"
    read -rp "  Type ERASE to wipe ${NODE}: " CONFIRM
    [[ "$CONFIRM" == "ERASE" ]] || die "Not confirmed — nothing was changed"
fi

# ── Step 5: erase / power off ───────────────────────────────────────────
if [[ "$ERASE" -eq 1 ]]; then
    echo
    info "${BOLD}Step 5: Erasing ${NODE}${CL}"
    out="$(rmn_erase_script | ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$(rn_node_fqdn "$NODE")" "bash -s" 2>&1)" || true
    printf '%s\n' "$out" | sed 's/^/    /'
    grep -qx ERASED <<<"$out" || die "the erase did not finish — ${NODE} is still in the cluster; check it on its console"
elif [[ "$ONLINE" -eq 1 ]]; then
    echo
    info "${BOLD}Step 5: Powering ${NODE} off${CL}"
    rn_node_ssh "$NODE" "systemctl poweroff" >/dev/null 2>&1 || true
fi
if [[ "$ONLINE" -eq 1 ]]; then
    waited=0
    while rn_node_ssh "$NODE" true 2>/dev/null; do
        sleep 5; waited=$((waited + 5))
        [[ "$waited" -lt "$OFF_WAIT" ]] || die "${NODE} is still up after ${OFF_WAIT}s — power it off, then run this again"
    done
    sleep 15   # corosync's token timeout: the peers notice it is gone
    info "  ${GN}✓${CL} ${NODE} is off"
fi
peer "pvecm status" 2>/dev/null | grep -q "Quorate:.*Yes" || die "the cluster is not quorate without ${NODE} — pvecm delnode needs quorum"

# ── Step 6: out of the cluster ──────────────────────────────────────────
echo
info "${BOLD}Step 6: Removing ${NODE} from the cluster${CL}"
if [[ "${#LOST_GUESTS[@]}" -gt 0 ]]; then
    mkdir -p "${LOST_DIR}"
    for g in "${LOST_GUESTS[@]}"; do
        read -r type vmid <<<"$g"
        dir=qemu-server; [[ "$type" == lxc ]] && dir=lxc
        peer "cat /etc/pve/nodes/${NODE}/${dir}/${vmid}.conf" > "${LOST_DIR}/${vmid}.conf" \
            || die "could not save ${type} ${vmid}'s config — nothing removed yet"
        # An HA guest HA could not recover keeps a resource for a config about
        # to go; the restore's module update registers it again.
        sid="vm:${vmid}"; [[ "$type" == lxc ]] && sid="ct:${vmid}"
        if peer "ha-manager config | grep -qx '${sid}'"; then
            peer "ha-manager remove ${sid}" >/dev/null 2>&1 && info "  ${GN}✓${CL} HA resource ${sid} removed" \
                || warn "  could not remove HA resource ${sid}"
        fi
    done
    info "  ${GN}✓${CL} ${#LOST_GUESTS[@]} lost guest config(s) saved → ${LOST_DIR}"
fi
if [[ "$LOST" -eq 1 ]]; then
    for j in "${REPL_JOBS[@]}"; do
        [[ -n "$j" ]] || continue
        peer "pvesh delete /cluster/replication/${j%% *} --force 1" >/dev/null 2>&1 \
            && info "  ${GN}✓${CL} replication job ${j%% *} removed" \
            || warn "  could not remove replication job ${j%% *} — pvesr delete ${j%% *} --force"
    done
fi
if [[ "$MEMBER" -eq 1 ]]; then
    peer "pvecm delnode ${NODE}" >/dev/null 2>&1 || die "pvecm delnode ${NODE} failed — run it on ${PEER} and read why"
    info "  ${GN}✓${CL} pvecm delnode ${NODE}"
fi
# Only an empty directory goes: a guest config in it would be a guest no check saw.
if peer "test -d /etc/pve/nodes/${NODE}"; then
    if [[ "$LOST" -eq 0 ]] && peer "ls /etc/pve/nodes/${NODE}/qemu-server/ /etc/pve/nodes/${NODE}/lxc/ 2>/dev/null | grep -q '\\.conf'"; then
        warn "  /etc/pve/nodes/${NODE} still holds guest configs — left in place; check them"
    else
        peer "rm -r /etc/pve/nodes/${NODE}" && info "  ${GN}✓${CL} /etc/pve/nodes/${NODE} removed"
    fi
fi
peer "ssh-keygen -R ${NODE} -f /etc/pve/priv/known_hosts >/dev/null 2>&1; ssh-keygen -R $(rn_node_fqdn "$NODE") -f /etc/pve/priv/known_hosts >/dev/null 2>&1; true"
for c in "${STOR_CHANGES[@]}"; do
    read -r verb s rest <<<"$c"
    if [[ "$verb" == set ]]; then
        peer "pvesm set ${s} --nodes ${rest}" && info "  ${GN}✓${CL} storage ${s}: ${rest}"
    else
        peer "pvesm remove ${s}" && info "  ${GN}✓${CL} storage ${s} removed (it was only on ${NODE})"
    fi
done

echo
info "${BOLD}${GN}✓${CL} ${NODE} is out of the cluster.${CL}"
