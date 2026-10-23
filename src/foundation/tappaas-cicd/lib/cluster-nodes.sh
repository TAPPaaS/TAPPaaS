# cluster-nodes.sh — the cluster's nodes, for the bash layer (ADR-036 D6).
#
# The nodes are their pvehost instances: config/<node>.json whose moduleSource
# is the pvehost module, not archived. The TypeScript managers list them with
# lib/ts/src/nodes.ts; these follow the same rules — by name, numbers as
# numbers (the first is the primary node), and while site.json still has the
# retired hardware.nodes[] (migration 0022 has not run) its nodes and pools
# fill what the instances lack.
#
# Re-exported by common-install-routines.sh; scripts that do not load the
# routines source this file on its own. Needs jq. Side-effect free: no logging.
# The config directory is TAPPAAS_CONFIG, else CONFIG_DIR, else the standard one.

[[ -n "${_CLUSTER_NODES_LIB_LOADED:-}" ]] && return 0
_CLUSTER_NODES_LIB_LOADED=1

# tappaas_cluster_nodes_json [config-dir] — [{name, address, storagePools}] in
# node order; [] when there are none.
tappaas_cluster_nodes_json() {
    local dir="${1:-${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}}" f
    local -a files=()
    for f in "${dir}"/*.json; do
        [[ -f "${f}" ]] && files+=("${f}")
    done
    local legacy='[]'
    if [[ -f "${dir}/site.json" ]]; then
        legacy="$(jq -c '[(.hardware.nodes // [])[]? | select(type == "object" and (.name | type) == "string" and .name != "")
                          | {name, storagePools: [(.storagePools // [])[]? | strings]}]' "${dir}/site.json" 2>/dev/null)" || legacy='[]'
        [[ -n "${legacy}" ]] || legacy='[]'
    fi
    local domain="${TAPPAAS_MGMT_DOMAIN:-mgmt.internal}"
    {
        for f in ${files[@]+"${files[@]}"}; do
            jq -c --arg n "$(basename "${f}" .json)" '
                select(type == "object"
                       and ((.moduleSource // .location // "") | type == "string" and test("(^|/)pvehost/*$"))
                       and (.status // "") != "archived")
                | {name: $n, address: (.address // ""), storagePools: (if (.storagePools | type) == "array" then [.storagePools[] | strings] else null end)}' \
                "${f}" 2>/dev/null
        done
    } | jq -sc --argjson legacy "${legacy}" --arg d "${domain}" '
        (map({key: .name, value: .}) | from_entries) as $inst
        | ($legacy | map({key: .name, value: .}) | from_entries) as $old
        | ([$inst | keys[]] + [$old | keys[]] | unique)
        | map(. as $n
              | ($inst[$n] // {name: $n, address: "", storagePools: null}) as $i
              | {name: $n,
                 address: (if ($i.address // "") != "" then $i.address else "\($n).\($d)" end),
                 storagePools: ($i.storagePools // $old[$n].storagePools // [])})
        | sort_by(.name | [scan("[0-9]+|[^0-9]+") | (tonumber? // .)])'
}

# tappaas_cluster_nodes [config-dir] — the node names, one per line, in node order.
tappaas_cluster_nodes() {
    tappaas_cluster_nodes_json "$@" | jq -r '.[].name'
}
