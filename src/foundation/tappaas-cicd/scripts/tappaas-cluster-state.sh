#!/usr/bin/env bash
#
# tappaas-cluster-state.sh — the cluster as one JSON document, for the alert
# receiver's node-down notice.
#
# Asks the first node that answers (and has quorum, if one does) for the nodes
# and the guests, then every online node for its HA CRM journal since --since:
# the CRM master logs a node's state changes and every recovery of a fenced
# node's HA services, and the master may have changed during the outage.
#
#   {"nodes":  [{"name": "tappaas2", "online": false}, …],
#    "quorate": true,
#    "guests": [{"vmid": 351, "name": "woodpecker", "type": "qemu",
#                "node": "tappaas2", "status": "unknown", "ha": "started"}, …],
#    "ha_log": ["2026-10-27T14:15:51+0100 tappaas1 pve-ha-crm[2197]: node 'tappaas2': state changed from 'online' => 'unknown'", …]}
#
# A guest on an offline node keeps that node and reads status "unknown"; an HA
# guest the CRM recovered is on its new node. `ha` is empty for a guest HA does
# not manage.
#
# Usage: tappaas-cluster-state.sh [--since TIME]   (journalctl's TIME; default -6h)
# Exit:  0 printed · 1 no node answered
set -uo pipefail

SINCE="-6h"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "tappaas-cluster-state: unknown option $1" >&2; exit 2 ;;
    esac
done

if [[ -r /home/tappaas/bin/cluster-nodes.sh ]]; then
    # shellcheck source=../lib/cluster-nodes.sh disable=SC1091
    . /home/tappaas/bin/cluster-nodes.sh
else
    # shellcheck source=../lib/cluster-nodes.sh disable=SC1091
    . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/cluster-nodes.sh"
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
nodes_json="$(tappaas_cluster_nodes_json)"
[[ "${nodes_json}" != "[]" && -n "${nodes_json}" ]] || nodes_json='[{"name":"tappaas1","address":"tappaas1.mgmt.internal"}]'
addr() { jq -r --arg n "$1" '(.[] | select(.name == $n) | .address) // "\($n).mgmt.internal"' <<<"${nodes_json}" | head -1; }

status=""; resources=""
for n in $(jq -r '.[].name' <<<"${nodes_json}"); do
    out="$("${SSH[@]}" "root@$(addr "${n}")" \
        'pvesh get /cluster/status --output-format json | tr -d "\n" && echo && pvesh get /cluster/resources --type vm --output-format json | tr -d "\n"' 2>/dev/null)" || continue
    s="$(sed -n 1p <<<"${out}")"; r="$(sed -n 2p <<<"${out}")"
    if ! jq -e 'type == "array"' <<<"${s}" >/dev/null 2>&1 || ! jq -e 'type == "array"' <<<"${r}" >/dev/null 2>&1; then
        continue
    fi
    status="${s}"; resources="${r}"
    # A node cut off from the rest answers too, but only a quorate one knows the cluster.
    jq -e 'any(.[]; .type == "cluster" and .quorate == 1)' <<<"${s}" >/dev/null 2>&1 && break
done
[[ -n "${status}" ]] || { echo "tappaas-cluster-state: no node answered" >&2; exit 1; }

ha_log=""
for n in $(jq -r '.[] | select(.type == "node" and .online == 1) | .name' <<<"${status}"); do
    ha_log+="$("${SSH[@]}" "root@$(addr "${n}")" \
        "journalctl -u pve-ha-crm -o short-iso --no-pager --since '${SINCE}' | grep -E \"state changed from|recover(ing)? service\"" 2>/dev/null)"$'\n'
done

jq -n --argjson s "${status}" --argjson r "${resources}" --arg log "${ha_log}" '{
    nodes: [$s[] | select(.type == "node") | {name, online: (.online == 1)}],
    quorate: any($s[]; .type == "cluster" and .quorate == 1),
    guests: [$r[] | select(.type == "qemu" or .type == "lxc")
             | {vmid, name: (.name // ""), type, node, status: (.status // ""), ha: (.hastate // "")}],
    ha_log: ($log | split("\n") | map(select(. != "")) | unique)
}'
