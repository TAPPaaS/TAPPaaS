#!/usr/bin/env bash
# ha-bridge-lib.sh — can a node carry an HA guest's network? (#836)
#
# A guest's NICs attach to Proxmox bridges by name (bridge0, bridge1: `lan`,
# `wan`, …). A node without one of them cannot start the guest: HA's failover
# there fails, and for the firewall that is the site offline. Nodes are added
# with `--no-wan`, so "every node has every bridge" is not a given.
#
#   habr_guest_bridges              the bridges the module's config declares
#                                   (get_config_value: bridge0, default lan; bridge1)
#   habr_node_bridges <node>        the bridges a node has, one per line;
#                                   rc 1 when the node does not answer
#   habr_missing <node> <bridge>... the ones the node lacks, one per line;
#                                   rc 1 when the node does not answer
#   habr_first_capable <primary> <bridge>...
#                                   the first other node with them all, or ""
#
# HABR_NODE_BRIDGES_CMD (tests) replaces the probe: `cmd <node>` prints names.

habr_guest_bridges() {
    local b0 b1
    b0="$(get_config_value 'bridge0' 'lan')"; [[ -z "${b0}" || "${b0}" == "null" ]] && b0="lan"
    b1="$(get_config_value 'bridge1' 'NONE')"
    printf '%s\n' "${b0}"
    [[ -n "${b1}" && "${b1}" != "NONE" && "${b1}" != "null" && "${b1}" != "${b0}" ]] && printf '%s\n' "${b1}"
    return 0
}

habr_node_bridges() {
    local node="$1"
    if [[ -n "${HABR_NODE_BRIDGES_CMD:-}" ]]; then
        ${HABR_NODE_BRIDGES_CMD} "${node}"
        return
    fi
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${node}.${MGMT:-mgmt}.internal" \
        "ip -br link show type bridge" 2>/dev/null | awk '{print $1}'
    return "${PIPESTATUS[0]}"
}

habr_missing() {
    local node="$1" have b; shift
    have="$(habr_node_bridges "${node}")" || return 1
    [[ -n "${have}" ]] || return 1
    for b in "$@"; do
        grep -qx -- "${b}" <<< "${have}" || printf '%s\n' "${b}"
    done
    return 0
}

habr_first_capable() {
    local primary="$1" n miss; shift
    for n in $(get_all_node_hostnames); do
        [[ "${n}" == "${primary}" ]] && continue
        miss="$(habr_missing "${n}" "$@")" || continue
        [[ -z "${miss}" ]] && { printf '%s' "${n}"; return 0; }
    done
    return 0
}
