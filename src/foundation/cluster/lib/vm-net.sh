# shellcheck shell=bash
# vm-net.sh — Shared VM-network helpers for the TAPPaaS cluster:vm service.
#
# Sourced (.) by services/vm/update-service.sh, which runs on tappaas-cicd and
# issues `qm` commands over ssh. These helpers resolve zone names to VLAN tags
# from zones.json and build / parse Proxmox `qm set --netN` option strings.
#
# The zone→tag and trunk-resolution semantics mirror Create-TAPPaaS-VM.sh
# (which runs on the Proxmox node); keep the two in sync if either changes.
#
# Requires: jq, and the logging helpers (info/warn/error/debug) from
# common-install-routines.sh to be sourced first.

VMNET_ZONES_FILE_DEFAULT="/home/tappaas/config/zones.json"

# Resolve a zone name to its VLAN tag.
#   vmnet_zone_vlantag <zone> [zones_file]
# Prints the tag (0 = untagged) on stdout. Returns 1 if the zone is undefined
# or inactive (matching Create-TAPPaaS-VM.sh's get_vlan_value).
vmnet_zone_vlantag() {
    local zone="$1"
    local zones_file="${2:-$VMNET_ZONES_FILE_DEFAULT}"

    if ! jq -e --arg z "$zone" 'has($z)' "$zones_file" >/dev/null 2>&1; then
        error "Zone '${zone}' is not defined in ${zones_file}"
        return 1
    fi
    local state tag
    state=$(jq -r --arg z "$zone" '.[$z].state // empty' "$zones_file")
    if [[ "$state" == "Inactive" ]]; then
        error "Zone '${zone}' is inactive (state: ${state})"
        return 1
    fi
    tag=$(jq -r --arg z "$zone" '.[$z].vlantag // 0' "$zones_file")
    echo -n "${tag}"
}

# Reverse-map a VLAN tag to the first zone name that uses it.
#   vmnet_zone_for_tag <tag> [zones_file]
# Prints the zone name (empty if none). Used to derive the *old* zone for DNS
# cleanup after a zone change. An empty/0 tag maps to the first untagged zone.
vmnet_zone_for_tag() {
    local tag="${1:-0}"
    local zones_file="${2:-$VMNET_ZONES_FILE_DEFAULT}"
    [[ -z "$tag" ]] && tag=0
    jq -r --argjson t "$tag" \
        'to_entries | map(select((.value.vlantag // 0) == $t)) | .[0].key // empty' \
        "$zones_file" 2>/dev/null
}

# Print the VLAN tags of every active zone, sorted and ';'-joined.
#   vmnet_all_active_tags [zones_file]
# "Active" here means state Active or Mandatory, with a non-zero tag (the
# untagged mgmt zone is excluded). This is the complete trunk list the firewall
# VM must carry so every routed VLAN reaches OPNsense. See issue #194.
vmnet_all_active_tags() {
    local zones_file="${1:-$VMNET_ZONES_FILE_DEFAULT}"
    jq -r '
        [ to_entries[]
          | select((.value.state == "Active" or .value.state == "Mandatory")
                   and ((.value.vlantag // 0) > 0))
          | .value.vlantag ]
        | sort | unique | map(tostring) | join(";")
    ' "$zones_file" 2>/dev/null
}

# Convert a ';'-separated list of trunk zone names to their VLAN tags.
#   vmnet_resolve_trunks "<z1;z2;...>" [zones_file]
# Prints "tag1;tag2;...". The sentinel "ALL" (or "*") expands to every active
# zone tag (vmnet_all_active_tags) — used so the firewall VM auto-trunks new
# zones without editing its config (issue #194). Undefined zone → error
# (return 1); inactive → skipped with a warning (matching resolve_trunks).
vmnet_resolve_trunks() {
    local zone_list="$1"
    local zones_file="${2:-$VMNET_ZONES_FILE_DEFAULT}"
    local result="" zone_name state tag
    local -a zone_names

    if [[ "$zone_list" == "ALL" || "$zone_list" == "*" ]]; then
        vmnet_all_active_tags "$zones_file"
        return 0
    fi

    IFS=';' read -ra zone_names <<< "$zone_list"
    for zone_name in "${zone_names[@]}"; do
        [[ -z "$zone_name" ]] && continue
        if ! jq -e --arg z "$zone_name" 'has($z)' "$zones_file" >/dev/null 2>&1; then
            error "Trunk zone '${zone_name}' is not defined in ${zones_file}"
            return 1
        fi
        state=$(jq -r --arg z "$zone_name" '.[$z].state // empty' "$zones_file")
        # Allowlist (#211): only Active, Mandatory, and Manual zones go on the
        # trunk. Inactive/Disabled and any future state are skipped with a
        # warning, mirroring what zone-manager actually pushes to OPNsense.
        # Manual zones are kept (operator-managed VLAN on OPNsense, but the VM
        # still needs the trunk to reach it) — the ALL sentinel excludes
        # Manual, but explicit lists respect operator intent.
        case "$state" in
            Active|Mandatory|Manual) ;;
            *)
                warn "Trunk zone '${zone_name}' (state: ${state:-<unset>}) is not trunkable, skipping"
                continue
                ;;
        esac
        tag=$(jq -r --arg z "$zone_name" '.[$z].vlantag // 0' "$zones_file")
        # Reject vlantag=0 — Proxmox tag=0 means untagged, which is meaningless
        # on a trunk list (would silently coalesce with the access port).
        if [[ "$tag" -le 0 ]]; then
            warn "Trunk zone '${zone_name}' has vlantag=${tag} (untagged), skipping"
            continue
        fi
        result="${result:+${result};}${tag}"
    done
    echo -n "${result}"
}

# Build a Proxmox `--netN` option string.
#   vmnet_build_netopts <bridge> <mac> <vlantag> <trunks> [queues]
# When a MAC is given, the model carries it inline as `virtio=<MAC>` — the
# canonical form Proxmox emits in `qm config` and round-trips cleanly. This is
# preferred over the bare-model + `macaddr=<MAC>` form, which some PVE versions
# reject as a duplicate `model` key on `qm set` (issue #204). <mac> empty →
# bare `virtio` (Proxmox keeps/generates a MAC). <vlantag> 0/empty → no tag.
# <trunks> empty/NONE → no trunks. <queues> empty/0 → no queues.
vmnet_build_netopts() {
    local bridge="$1" mac="$2" tag="$3" trunks="$4" queues="${5:-}"
    local opts
    if [[ -n "$mac" ]]; then
        opts="virtio=${mac},bridge=${bridge}"
    else
        opts="virtio,bridge=${bridge}"
    fi
    [[ -n "$tag" && "$tag" != "0" ]] && opts="${opts},tag=${tag}"
    [[ -n "$trunks" && "$trunks" != "NONE" ]] && opts="${opts},trunks=${trunks}"
    [[ -n "$queues" && "$queues" != "0" ]] && opts="${opts},queues=${queues}"
    echo -n "${opts}"
}

# Extract one field from a live `qm config` net line.
#   vmnet_parse "<netline>" <field>
# <netline> is the value after "netN:" e.g. "virtio=02:..,bridge=lan,tag=210".
# <field> is one of: mac | bridge | tag | trunks | queues. Prints the value
# (empty if absent). The model=MAC token (e.g. virtio=02:..) yields the mac.
vmnet_parse() {
    local line="$1" field="$2"
    local -a parts
    IFS=',' read -ra parts <<< "$line"
    local p k v
    for p in "${parts[@]}"; do
        k="${p%%=*}"
        v="${p#*=}"
        case "$field" in
            mac)
                # model token: e.g. "virtio=02:7A:..". Match a known NIC model key.
                case "$k" in
                    virtio|e1000|e1000e|rtl8139|vmxnet3) echo -n "$v"; return 0 ;;
                esac
                ;;
            bridge) [[ "$k" == "bridge" ]] && { echo -n "$v"; return 0; } ;;
            tag)    [[ "$k" == "tag" ]]    && { echo -n "$v"; return 0; } ;;
            trunks) [[ "$k" == "trunks" ]] && { echo -n "$v"; return 0; } ;;
            queues) [[ "$k" == "queues" ]] && { echo -n "$v"; return 0; } ;;
        esac
    done
    echo -n ""
}
