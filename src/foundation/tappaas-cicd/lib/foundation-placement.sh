# shellcheck shell=bash
#
# foundation-placement.sh — where the foundation's guests go: the proposal Rest
# of foundation shows and the choices each row has (install-simplification plan,
# step 3). Sourced by rest-of-foundation.sh; the console reads the same proposal
# through `rest-of-foundation.sh --proposal`, so the rules live here only.
#
#   fp_facts                 the machines as Proxmox reports them (JSON):
#                            memory, pools, boot pool, bridges, guests and their pool
#   fp_proposal <facts>      the proposal (JSON): the machines in short, and a row per
#                            module with its current place, the proposed one and
#                            the choices
#   fp_check <proposal> <module> <node> <ha> <storage>
#                            empty when the choice is one the row offers, else why
#
# The rows: network and tappaas-cicd are installed by the bootstrap and are
# moved (a guest on the boot pool goes to tanka1 when its machine has one);
# backup, identity and logging are installed. A guest's pool is chosen as the
# create path chooses it (cluster/lib/storage-placement.sh, sp_choose). With an
# HA machine the pool must be on both, since replication writes the same pool on
# the failover machine; an HA machine must have the guest's bridges
# (cluster/lib/ha-bridge-lib.sh). backup is a Proxmox Backup Server whose
# datastore is a tankc pool (backup/lib/pbs-placement.sh): it prefers a machine
# other than the mothership's.
#
# FP_FACTS_FILE (tests) replaces fp_facts; FP_CONFIG_DIR and FP_SRC the config
# and module directories.

FP_MODULES=(network tappaas-cicd backup identity logging)

_fp_config() { printf '%s' "${FP_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"; }
_fp_src() { printf '%s' "${FP_SRC:-/home/tappaas/TAPPaaS/src/foundation}"; }

# The module's record: its deployed config when installed, else its release json.
_fp_module_json() {
    local m="$1" f
    f="$(_fp_config)/${m}.json"
    [[ -f "${f}" ]] || f="$(_fp_src)/${m}/${m}.json"
    [[ -f "${f}" ]] && cat "${f}" || printf '{}'
}

# One machine's facts, read on it as root: the pools that hold guest disks, the
# boot pool's storage, its bridges, its memory and the guests with their pool.
_fp_node_facts() {
    local node="$1"
    # shellcheck disable=SC2016
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${node}.mgmt.internal" '
        n="$(hostname -s)"
        echo "##storage"; pvesh get "/nodes/${n}/storage" --enabled 1 --output-format json 2>/dev/null || echo "[]"
        echo; echo "##status"; pvesh get "/nodes/${n}/status" --output-format json 2>/dev/null || echo "{}"
        echo; echo "##boot"; awk '"'"'$1=="zfspool:" {id=$2; next} id && $1=="pool" && $2=="rpool/data" {print id; exit} /^[^ \t]/ {id=""}'"'"' /etc/pve/storage.cfg 2>/dev/null
        echo "##bridges"; ip -br link show type bridge 2>/dev/null | awk "{print \$1}"
        echo "##guests"
        for v in $(qm list 2>/dev/null | awk "NR>1 {print \$1}"); do
            c="$(qm config "$v" 2>/dev/null)"
            printf "%s %s\n" "$(printf "%s\n" "$c" | sed -n "s/^name: //p")" "$(printf "%s\n" "$c" | sed -n -E "s/^(scsi0|virtio0|sata0): ([^:,]+):.*/\2/p" | head -1)"
        done' 2>/dev/null
}

# The sections _fp_node_facts printed, as one JSON object.
_fp_parse_node() {
    local node="$1" text="$2" sect="" storage="" status="" boot="" bridges="" guests=""
    while IFS= read -r line; do
        case "${line}" in
            "##"*) sect="${line#\#\#}"; continue ;;
        esac
        case "${sect}" in
            storage) storage+="${line}" ;;
            status) status+="${line}" ;;
            boot) [[ -n "${line}" ]] && boot="${line}" ;;
            bridges) [[ -n "${line}" ]] && bridges+="${line}"$'\n' ;;
            guests) [[ -n "${line}" ]] && guests+="${line}"$'\n' ;;
        esac
    done <<< "${text}"
    jq -nc --arg name "${node}" --arg boot "${boot}" --arg bridges "${bridges}" --arg guests "${guests}" \
        --argjson storage "${storage:-[]}" --argjson status "${status:-{\}}" '
        { name: $name,
          memory: ($status.memory.total // 0),
          boot: $boot,
          storages: [ $storage[] | select(.active == 1 or .active == null) | { name: .storage, type: .type, images: ((.content // "") | split(",") | index("images") != null), total: (.total // 0), avail: (.avail // 0) } ],
          bridges: ($bridges | split("\n") | map(select(. != ""))),
          guests: ($guests | split("\n") | map(select(. != "") | split(" ") | { name: .[0], storage: (.[1] // "") })) }'
}

fp_facts() {
    if [[ -n "${FP_FACTS_FILE:-}" ]]; then cat "${FP_FACTS_FILE}"; return; fi
    local n out all=()
    for n in $(get_all_node_hostnames); do
        out="$(_fp_node_facts "${n}")" || out=""
        all+=("$(_fp_parse_node "${n}" "${out}")")
    done
    printf '%s\n' "${all[@]}" | jq -sc '{ nodes: . }'
}

# The pools of a machine that can hold a guest (ZFS: replication needs it), one per line.
_fp_zfs() { jq -r --arg n "$2" '.nodes[] | select(.name == $n) | .storages[] | select(.type == "zfspool" and .images) | .name' <<< "$1"; }
_fp_boot() { jq -r --arg n "$2" '.nodes[] | select(.name == $n) | .boot' <<< "$1"; }

# A guest row's proposal, given where it is: its pool by sp_choose, its HA machine
# the first other one with its bridges and that pool.
_fp_guest_row() {
    local facts="$1" m="$2" cfg installed=false cur_node="" cur_storage="" cur_ha="" ha_capable=false bridges node want zfs boot storage ha="" first
    cfg="$(_fp_module_json "${m}")"
    [[ -f "$(_fp_config)/${m}.json" ]] && installed=true
    jq -e '(.dependsOn // []) | index("cluster:ha")' <<< "${cfg}" >/dev/null && ha_capable=true
    bridges="$(jq -c '[(.bridge0 // "lan"), (.bridge1 // "NONE")] | map(select(. != "NONE" and . != null and . != "")) | unique' <<< "${cfg}")"
    first="$(jq -r '.nodes[0].name // ""' <<< "${facts}")"
    if [[ "${installed}" == true ]]; then
        read -r cur_node cur_storage < <(jq -r --arg m "${m}" '[.nodes[] | .name as $n | .guests[] | select(.name == $m) | "\($n) \(.storage)"][0] // ""' <<< "${facts}")
        cur_ha="$(jq -r '.HANode // ""' <<< "${cfg}")"
    fi
    node="${cur_node:-$(jq -r '.node // ""' <<< "${cfg}")}"
    [[ -n "${node}" ]] && jq -e --arg n "${node}" '.nodes | any(.name == $n)' <<< "${facts}" >/dev/null || node="${first}"
    zfs="$(_fp_zfs "${facts}" "${node}")"
    boot="$(_fp_boot "${facts}" "${node}")"
    # A guest on the boot pool moves to a data pool when its machine has one.
    if [[ -n "${cur_storage}" && "${cur_storage}" != "${boot}" ]]; then want="${cur_storage}"; else want="$(jq -r '.storage // "tanka1"' <<< "$(cat "$(_fp_src)/${m}/${m}.json" 2>/dev/null || echo '{}')")"; fi
    [[ "${want}" == "null" || -z "${want}" ]] && want="tanka1"
    storage="$(sp_choose "${want}" "${zfs}" "${zfs}" "${boot}" 2>/dev/null)" || storage=""
    if [[ "${ha_capable}" == true ]]; then
        if [[ -n "${cur_ha}" ]]; then ha="${cur_ha}"
        else
            ha="$(jq -r --arg n "${node}" --arg s "${storage}" --argjson b "${bridges}" \
                '[.nodes[] | select(.name != $n and (.bridges as $have | $b | all(. as $x | $have | index($x))) and (.storages | any(.name == $s)))][0].name // ""' <<< "${facts}")"
        fi
    fi
    jq -nc --arg m "${m}" --argjson installed "${installed}" --argjson ha_capable "${ha_capable}" --argjson b "${bridges}" \
        --arg cn "${cur_node}" --arg cs "${cur_storage}" --arg ch "${cur_ha}" \
        --arg node "${node}" --arg storage "${storage}" --arg ha "${ha}" --argjson facts "${facts}" '
        def zfs($n): [$facts.nodes[] | select(.name == $n) | .storages[] | select(.type == "zfspool" and .images) | .name]
          | (map(select(test("^tank"))) | sort) + (map(select(test("^tank") | not)) | sort);
        def capable: [$facts.nodes[] | select(.bridges as $have | $b | all(. as $x | $have | index($x))) | .name];
        { module: $m, kind: "guest", installed: $installed,
          current: (if $installed and $cn != "" then { node: $cn, storage: $cs, ha: $ch } else null end),
          proposal: { node: $node, storage: $storage, ha: $ha },
          choices: (capable | map(. as $n | { key: $n, value: (
            (if $ha_capable then (capable | map(select(. != $n))) else [] end) as $has
            | { ha: $has,
                pools: ({ "": zfs($n) } + ($has | map(. as $h | { key: $h, value: (zfs($n) - (zfs($n) - zfs($h))) }) | from_entries)) }) }) | from_entries),
          note: (if ($b | index("wan")) then "needs the WAN bridge on its machine" else null end) }'
}

# backup: the machine whose tankc pool holds the datastore, else a placeholder.
_fp_backup_row() {
    local facts="$1" cfg installed=false mother node="" storage="" cur=null
    cfg="$(_fp_module_json backup)"
    [[ -f "$(_fp_config)/backup.json" ]] && installed=true
    mother="$(jq -r '[.nodes[] | select(.guests | any(.name == "tappaas-cicd")) | .name][0] // ""' <<< "${facts}")"
    if [[ "${installed}" == true ]]; then
        cur="$(jq -c '{ node: (.node // ""), storage: (if (.placementState // "") == "node" then (.storage // "") else "" end), ha: "" }' <<< "${cfg}")"
    fi
    read -r node storage < <(jq -r --arg mo "${mother}" '
        [.nodes[] | { name, pools: [.storages[] | select(.type == "zfspool" and (.name | test("^tankc"))) | .name] | sort } | select(.pools | length > 0)]
        | (map(select(.name != $mo)) + map(select(.name == $mo)))[0] // empty
        | "\(.name) \(if (.pools | index("tankc1")) then "tankc1" else .pools[0] end)"' <<< "${facts}")
    jq -nc --argjson installed "${installed}" --argjson cur "${cur}" --arg node "${node}" --arg storage "${storage}" --argjson facts "${facts}" '
        { module: "backup", kind: "backup", installed: $installed,
          current: $cur,
          proposal: { node: $node, storage: $storage, ha: "" },
          choices: ([$facts.nodes[] | { key: .name, value: { ha: [], pools: { "": ([.storages[] | select(.type == "zfspool" and (.name | test("^tankc"))) | .name] | sort) } } } | select(.value.pools[""] | length > 0)] | from_entries),
          note: (if $node == "" then "no tankc pool on any machine: backup is a placeholder until one is added" else null end) }'
}

fp_proposal() {
    local facts="$1" m rows=()
    for m in "${FP_MODULES[@]}"; do
        if [[ "${m}" == backup ]]; then rows+=("$(_fp_backup_row "${facts}")"); else rows+=("$(_fp_guest_row "${facts}" "${m}")"); fi
    done
    printf '%s\n' "${rows[@]}" | jq -sc --argjson facts "${facts}" '
        { nodes: [$facts.nodes[] | .boot as $boot | { name, memoryGiB: ((.memory / 1073741824) | floor),
            pools: [.storages[] | select(.type == "zfspool") | { name, sizeGiB: ((.total / 1073741824) | floor), freeGiB: ((.avail / 1073741824) | floor), boot: (.name == $boot) }] }],
          rows: . }'
}

fp_check() {
    local proposal="$1" m="$2" node="$3" ha="$4" storage="$5"
    jq -r --arg m "${m}" --arg n "${node}" --arg h "${ha}" --arg s "${storage}" '
        (.rows[] | select(.module == $m)) as $r
        | if $r == null then "\($m): not a foundation module"
          elif ($r.choices[$n] == null) then "\($m): \($n) is not a machine it can run on"
          elif ($h != "" and ($r.choices[$n].ha | index($h) | not)) then "\($m): \($h) cannot be its HA machine"
          elif (($r.choices[$n].pools[$h] // []) | index($s) | not) then "\($m): \($s) is not a pool on \($n)\(if $h != "" then " and \($h)" else "" end)"
          else empty end' <<< "${proposal}"
}
