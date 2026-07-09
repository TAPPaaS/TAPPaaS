#!/usr/bin/env bash
#
# reconcile-storage-nodes.sh — drift-heal the cluster storage `nodes` lists
# from site.json (docs/design/node-provisioning.md §7.3 finding 4).
#
# site.json declares which nodes carry which pools (.hardware.nodes[]
# .storagePools). The live truth is /etc/pve/storage.cfg's per-pool `nodes`
# list — and that list has only ONE-SHOT writers (config-storage.sh at pool
# creation, `site-manager node add` after a join), so any other path leaves
# it drifted: a node joined before the node-add fix existed, a manual
# `pvesm set`, a cluster config restore. Symptom: `pvesm status` shows the
# pool 'disabled' on a node that has it ONLINE in zfs.
#
# Converge rule (mirrors the site-manager reconcile doctrine):
#   - a site.json-declared node MISSING from the pool's list is ADDED;
#   - an extra node in the list is WARNED about, never removed (operator
#     hand-edits are legitimate; removal is an operator decision);
#   - a pool with NO `nodes` restriction is left alone (unrestricted =
#     available everywhere = superset of desired);
#   - a declared pool with no storage.cfg entry at all is warned about
#     (creating entries is config-storage.sh's job, not ours).
#
# Runs on the tappaas-cicd mothership (site.json + ssh to the primary
# node); invoked by cluster/update.sh every update cycle and safe to run
# standalone. Idempotent. Exit 0 = converged/no-op, 1 = error.
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SITE_JSON="${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json"
NODE1_FQDN="$(get_primary_node_fqdn)"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

[[ -f "$SITE_JSON" ]] || { error "site.json not found: $SITE_JSON"; exit 1; }

# All pools declared by any node in site.json.
mapfile -t POOLS < <(jq -r '[.hardware.nodes[].storagePools[]?] | unique | .[]' "$SITE_JSON")
if [[ "${#POOLS[@]}" -eq 0 ]]; then
    info "site.json declares no storage pools — nothing to reconcile"
    exit 0
fi

CHANGED=0
for pool in "${POOLS[@]}"; do
    desired="$(jq -r --arg p "$pool" \
        '[.hardware.nodes[] | select((.storagePools // []) | index($p)) | .name] | join(",")' \
        "$SITE_JSON")"

    if ! ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" \
            "grep -q '^zfspool: ${pool}\$' /etc/pve/storage.cfg" 2>/dev/null; then
        warn "pool '${pool}' declared in site.json but has no storage.cfg entry — create it with config-storage.sh"
        continue
    fi

    current="$(ssh -n "${SSH_OPTS[@]}" root@"$NODE1_FQDN" \
        "sed -n '/^zfspool: ${pool}\$/,/^\$/s/^[[:space:]]*nodes //p' /etc/pve/storage.cfg" \
        2>/dev/null | head -1)"

    if [[ -z "$current" ]]; then
        debug "  ${pool}: no nodes restriction (available everywhere) — leaving as-is"
        continue
    fi

    # Missing = declared in site.json but absent from the live list.
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
            *) warn "  ${pool}: '${n}' is in the storage nodes list but site.json does not declare the pool for it (not removing — operator decision)" ;;
        esac
    done

    if [[ -z "$missing" ]]; then
        debug "  ${pool}: nodes list matches site.json (${current})"
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
    info "Storage nodes lists already match site.json"
fi
