#!/usr/bin/env bash
#
# reconcile-storage-nodes.sh — drift-heal the cluster storage `nodes` lists
# from the nodes' records (docs/design/node-provisioning.md §7.3 finding 4).
#
# Each node's pvehost instance declares the pools it carries (storagePools;
# tappaas_cluster_nodes_json lists them). The live truth is /etc/pve/storage.cfg's per-pool `nodes`
# list — and that list has only ONE-SHOT writers (config-storage.sh at pool
# creation, `site-manager node add` after a join), so any other path leaves
# it drifted: a node joined before the node-add fix existed, a manual
# `pvesm set`, a cluster config restore. Symptom: `pvesm status` shows the
# pool 'disabled' on a node that has it ONLINE in zfs.
#
# Also: an lvmthin storage (the installer's local-lvm) covers exactly the nodes
# that have its thin pool — see below.
#
# Converge rule for the data pools (mirrors the site-manager reconcile doctrine):
#   - a node that declares the pool but is MISSING from its list is ADDED;
#   - an extra node in the list is WARNED about, never removed (operator
#     hand-edits are legitimate; removal is an operator decision);
#   - a pool with NO `nodes` restriction is left alone (unrestricted =
#     available everywhere = superset of desired);
#   - a declared pool with no storage.cfg entry at all is warned about
#     (creating entries is config-storage.sh's job, not ours).
#
# Runs on the tappaas-cicd mothership (the node records + ssh to the primary
# node); invoked by cluster/update.sh every update cycle and safe to run
# standalone. Idempotent. Exit 0 = converged/no-op, 1 = error.
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

NODES_JSON="$(tappaas_cluster_nodes_json "${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}")"
NODE1_FQDN="$(get_primary_node_fqdn)"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

CHANGED=0

# ── the installer's thin pool (local-lvm) ────────────────────────────
# Proxmox's ext4/LVM install registers lvmthin storage `local-lvm` (pve/data)
# for every node; a node installed on ZFS has no pve/data, so there it reads
# inactive, and everything that walks the storages trips on it (a nightly
# update's cloud-init sweep did). Its nodes list is set to the nodes that have
# its thin pool — a node without it can hold nothing there. Left alone when
# every node has it, and when none does (then it is warned about).
mapfile -t NODE_NAMES < <(jq -r '.[].name' <<<"$NODES_JSON")
storage_cfg="$(ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" "cat /etc/pve/storage.cfg" 2>/dev/null)" || storage_cfg=""
while read -r lv _vg _tp _nodes; do
    [[ -n "$lv" ]] || continue
    have=""
    for n in "${NODE_NAMES[@]}"; do
        if ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=10 root@"${n}.mgmt.internal" "lvs --noheadings ${_vg}/${_tp}" >/dev/null 2>&1; then
            have="${have:+${have},}${n}"
        fi
    done
    if [[ -z "$have" ]]; then
        warn "  ${lv}: no node has its thin pool ${_vg}/${_tp} — the storage holds nothing (pvesm remove ${lv} if it is not wanted)"
        continue
    fi
    if [[ "$have" == "$(IFS=,; echo "${NODE_NAMES[*]}")" && "$_nodes" == "-" ]]; then
        debug "  ${lv}: every node has ${_vg}/${_tp}"
        continue
    fi
    sorted() { tr ',' '\n' <<<"$1" | sort | paste -sd, -; }
    [[ "$(sorted "$_nodes")" == "$(sorted "$have")" ]] && { debug "  ${lv}: nodes ${have}"; continue; }
    info "  ${lv}: limited to the nodes with ${_vg}/${_tp} (${_nodes/#-/all} -> ${have})"
    if ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" "pvesm set '${lv}' --nodes '${have}'"; then
        CHANGED=$((CHANGED + 1))
    else
        error "  pvesm set ${lv} --nodes ${have} failed on ${NODE1_FQDN}"
        exit 1
    fi
done < <(awk '
    /^[a-z]+: / { if (name != "" && type == "lvmthin") print name, vg, tp, (nodes == "" ? "-" : nodes)
                  split($0, h, ": "); type = h[1]; name = h[2]; vg = ""; tp = ""; nodes = ""; next }
    $1 == "vgname"   { vg = $2 }
    $1 == "thinpool" { tp = $2 }
    $1 == "nodes"    { nodes = $2 }
    END { if (name != "" && type == "lvmthin") print name, vg, tp, (nodes == "" ? "-" : nodes) }' <<<"$storage_cfg")

# All pools declared by any node.
mapfile -t POOLS < <(jq -r '[.[].storagePools[]?] | unique | .[]' <<<"$NODES_JSON")
if [[ "${#POOLS[@]}" -eq 0 ]]; then
    debug "no node declares a storage pool — nothing to reconcile"
    [[ "$CHANGED" -gt 0 ]] && info "Storage nodes lists reconciled (${CHANGED} storage(s) updated)"
    exit 0
fi

for pool in "${POOLS[@]}"; do
    desired="$(jq -r --arg p "$pool" \
        '[.[] | select(.storagePools | index($p)) | .name] | join(",")' <<<"$NODES_JSON")"

    if ! ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" \
            "grep -q '^zfspool: ${pool}\$' /etc/pve/storage.cfg" 2>/dev/null; then
        warn "pool '${pool}' declared by a node but has no storage.cfg entry — create it with config-storage.sh"
        continue
    fi

    current="$(ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" \
        "sed -n '/^zfspool: ${pool}\$/,/^\$/s/^[[:space:]]*nodes //p' /etc/pve/storage.cfg" \
        2>/dev/null | head -1)"

    if [[ -z "$current" ]]; then
        debug "  ${pool}: no nodes restriction (available everywhere) — leaving as-is"
        continue
    fi

    # Missing = declared by the node but absent from the live list.
    missing=""
    for n in ${desired//,/ }; do
        case ",${current}," in
            *",${n},"*) ;;
            *) missing="${missing:+${missing},}${n}" ;;
        esac
    done
    # Extras = in the live list but not declared — warn only.
    for n in ${current//,/ }; do
        case ",${desired}," in
            *",${n},"*) ;;
            *) warn "  ${pool}: '${n}' is in the storage nodes list but its record does not declare the pool (not removing — operator decision)" ;;
        esac
    done

    if [[ -z "$missing" ]]; then
        debug "  ${pool}: nodes list matches the node records (${current})"
        continue
    fi

    newlist="${current},${missing}"
    info "  ${pool}: adding [${missing}] to storage nodes (${current} -> ${newlist})"
    if ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" "pvesm set '${pool}' --nodes '${newlist}'"; then
        CHANGED=$((CHANGED + 1))
    else
        error "  pvesm set ${pool} --nodes ${newlist} failed on ${NODE1_FQDN}"
        exit 1
    fi
done

if [[ "$CHANGED" -gt 0 ]]; then
    info "Storage nodes lists reconciled (${CHANGED} pool(s) updated)"
else
    debug "Storage nodes lists already match the node records"
fi
