#!/usr/bin/env bash
# nfs-lib.sh — the parts of pvehost:nfs (ADR-029) that need no node and no guest:
# reading a share reference, rendering an export's `sharenfs`, checking an
# export declaration, and allocating an export's owner. Pure functions over
# config/ JSON, so the fast tier can test them (test-nfs-lib.sh).
#
# Sourced after common-install-routines.sh (or on its own by the tests).

NFS_CONFIG_DIR="${NFS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"
# ADR-029 D5 (Q2): one uid/gid pair per export, from a range no Debian or NixOS
# default allocates.
NFS_OWNER_MIN=64000
NFS_OWNER_MAX=64999
# ADR-029 D4: every export lives under this parent, so nothing TAPPaaS shares can
# be mistaken for a Proxmox VM disk (<pool>/vm-<id>-disk-<n>).
NFS_PARENT="tappaas-nfs"
NFS_NAME_RE='^[a-z][a-z0-9-]*$'

# nfs_parse_share_ref <ref> — ADR-029 D2. Prints one line:
#   named <instance> <name>     no leading slash after the colon
#   literal <host> <path>       a leading slash: an unmodelled server's path
# rc 1 (and a reason on stderr) for anything else.
nfs_parse_share_ref() {
    local ref="$1" host rest
    [[ "${ref}" == *:* ]] || { echo "share '${ref}' is not <host>:<name> or <host>:/<path>" >&2; return 1; }
    host="${ref%%:*}"; rest="${ref#*:}"
    [[ -n "${host}" && -n "${rest}" ]] || { echo "share '${ref}' has an empty host or name" >&2; return 1; }
    if [[ "${rest}" == /* ]]; then
        printf 'literal %s %s\n' "${host}" "${rest}"
    else
        [[ "${rest}" =~ ${NFS_NAME_RE} ]] || { echo "share name '${rest}' must match ${NFS_NAME_RE}" >&2; return 1; }
        printf 'named %s %s\n' "${host}" "${rest}"
    fi
}

# nfs_is_instance <name> — rc 0 when config/<name>.json exists: a module instance
# TAPPaaS knows (ADR-026 D6.1).
nfs_is_instance() { [[ -f "${NFS_CONFIG_DIR}/$1.json" ]]; }

# nfs_instance_managed <instance> — rc 0 when the instance is a managed Host
# whose exports TAPPaaS builds; rc 1 for a registered, unmanaged server.
nfs_instance_managed() {
    [[ "$(jq -r '.management // "managed"' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null)" == "managed" ]]
}

# nfs_exports <instance> — the instance's nfs.exports[] as compact JSON, one per line.
nfs_exports() { jq -c '.nfs.exports // [] | .[]' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null; }

# nfs_export <instance> <name> — one export's declaration; rc 1 when absent.
nfs_export() {
    jq -ce --arg n "$2" '.nfs.exports // [] | map(select(.name == $n)) | .[0] // empty' \
        "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null | grep . || return 1
}

# nfs_dataset <pool> <name> — the dataset an export lives in.
nfs_dataset() { printf '%s/%s/%s\n' "$1" "${NFS_PARENT}" "$2"; }

# nfs_check_export <export-json> <managed|unmanaged> — ADR-029 D4 / D2a. Prints one
# problem per line; rc 1 when there is any. The shape checks only: whether the
# pool exists is a question for the node.
nfs_check_export() {
    local e="$1" mode="$2"
    jq -r --arg mode "${mode}" --arg re "${NFS_NAME_RE}" --argjson min "${NFS_OWNER_MIN}" --argjson max "${NFS_OWNER_MAX}" '
      (.name // "<unnamed>") as $nm |
      [
        (if (.name | type) != "string" or (.name | test($re) | not)
           then "export \($nm): name must match \($re)" else empty end),
        (.grants // [] | .[] |
           if (.consumer | type) != "string" or .consumer == "" then "export \($nm): a grant has no consumer"
           elif (.access // "ro") as $a | ($a != "ro" and $a != "rw") then "export \($nm): grant for \(.consumer) has access \(.access) (ro|rw)"
           else empty end),
        (if ((.grants // []) | map(.consumer) | (length != (unique | length)))
           then "export \($nm): a consumer is granted twice" else empty end),
        (if $mode == "managed" then
           (if (.pool | type) != "string" or .pool == "" then "export \($nm): pool is required on a managed Host" else empty end),
           (if has("path") then "export \($nm): path is for a registered, unmanaged server — a managed Host builds the dataset from pool" else empty end),
           (if (.backup.enabled | type) != "boolean"
              then "export \($nm): backup.enabled must be stated, true or false (ADR-029 D9 — there is no default)" else empty end),
           (if has("owner") and ((.owner.uid | type) != "number" or (.owner.gid | type) != "number"
                                 or .owner.uid < $min or .owner.uid > $max or .owner.gid < $min or .owner.gid > $max)
              then "export \($nm): owner must be {uid, gid} in \($min)-\($max)" else empty end),
           (.properties // {} | keys[] | select(IN("recordsize", "compression", "atime") | not)
              | "export \($nm): property \(.) is not one TAPPaaS sets (recordsize, compression, atime)")
         else
           (if (.path | type) != "string" or (.path | startswith("/") | not)
              then "export \($nm): path (absolute) is required on a registered, unmanaged server" else empty end),
           (["pool", "quota", "owner", "properties", "backup"][] as $k | select(has($k))
              | "export \($nm): \($k) is not allowed on a registered, unmanaged server — TAPPaaS does not provision it"),
           (if ((.version // "4.2") | IN("4.2", "4.1", "4.0", "3") | not)
              then "export \($nm): version \(.version) (4.2|4.1|4.0|3)" else empty end),
           (if (.version // "4.2") == "3" and ((.v3Ports.mountd | type) != "number"
                 or (.v3Ports.nlockmgr | type) != "number" or (.v3Ports.statd | type) != "number")
              then "export \($nm): NFSv3 needs v3Ports {mountd, nlockmgr, statd} pinned — dynamic ports cannot be firewalled per host" else empty end)
         end)
      ] | .[]' <<< "${e}" | grep . && return 1
    return 0
}

# nfs_render_sharenfs <uid> <gid> <rw-addrs> <ro-addrs> — ADR-029 D4a. The addresses
# are space-separated IPs. Prints the value for `zfs set sharenfs=`; "off" when
# nobody is granted, never "on" (which OpenZFS shares to everyone).
#
# root_squash is written explicitly because OpenZFS's Linux libshare starts every
# share from no_squash defaults (no_subtree_check,no_root_squash,mountpoint) and
# only an option given later overrides it. `mountpoint` stays from those
# defaults: it is what refuses to export an unmounted dataset's empty directory.
nfs_render_sharenfs() {
    local uid="$1" gid="$2" rw="$3" ro="$4" opts=() a
    local rwl="" rol=""
    for a in ${rw}; do rwl+="${rwl:+:}@${a}/32"; done
    for a in ${ro}; do rol+="${rol:+:}@${a}/32"; done
    [[ -n "${rwl}${rol}" ]] || { printf 'off\n'; return 0; }
    [[ -n "${rwl}" ]] && opts+=("rw=${rwl}")
    [[ -n "${rol}" ]] && opts+=("ro=${rol}")
    opts+=("sec=sys" "root_squash" "all_squash" "anonuid=${uid}" "anongid=${gid}" "no_subtree_check")
    local IFS=,
    printf '%s\n' "${opts[*]}"
}

# nfs_allocated_owners — every owner uid already written into any instance's
# exports, one per line.
nfs_allocated_owners() {
    local f
    for f in "${NFS_CONFIG_DIR}"/*.json; do
        [[ -f "${f}" ]] || continue
        jq -r '.nfs.exports // [] | .[] | .owner.uid // empty' "${f}" 2>/dev/null
    done
}

# nfs_next_owner — the lowest free uid in the range, across the whole Site, so two
# nodes never hand out the same owner (a consumer may mount from both). rc 1 when
# the range is exhausted.
nfs_next_owner() {
    local used u
    used="$(nfs_allocated_owners | sort -n | uniq)"
    for (( u = NFS_OWNER_MIN; u <= NFS_OWNER_MAX; u++ )); do
        grep -qx "${u}" <<< "${used}" || { printf '%s\n' "${u}"; return 0; }
    done
    return 1
}

# nfs_grants_for <instance> <export> <consumer> — the access a consumer is granted
# on one export ("ro"/"rw"), empty when it has none.
nfs_grant_for() {
    jq -r --arg n "$2" --arg c "$3" \
        '.nfs.exports // [] | .[] | select(.name == $n) | .grants // [] | .[] | select(.consumer == $c) | (.access // "ro")' \
        "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null | head -1
}

# nfs_mounts <consumer> — the consumer's config."pvehost:nfs".mounts[], compact, one per line.
nfs_mounts() { jq -c '.config["pvehost:nfs"].mounts // [] | .[]' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null; }

# nfs_check_mount <consumer> <mount-json> — ADR-029 D3 + D11: the mount's own shape,
# and, for a named share, the two-key check against the export it names. Prints
# one problem per line; rc 1 when there is any.
nfs_check_mount() {
    local consumer="$1" m="$2" path share access parsed kind host name grant
    path="$(jq -r '.path // empty' <<< "${m}")"
    share="$(jq -r '.share // empty' <<< "${m}")"
    access="$(jq -r '.access // "ro"' <<< "${m}")"
    local bad=0
    case "${path}" in
        "") echo "mount: path is required"; bad=1 ;;
        /|/nix|/nix/*|/etc|/etc/*|/var|/boot|/boot/*|/proc*|/sys*|/dev*|/run*|/usr|/usr/*|/bin*|/sbin*|/lib*)
            echo "mount ${path}: not a directory a share may cover"; bad=1 ;;
        /*) ;;
        *) echo "mount ${path}: path must be absolute"; bad=1 ;;
    esac
    [[ "${access}" == "ro" || "${access}" == "rw" ]] || { echo "mount ${path}: access ${access} (ro|rw)"; bad=1; }
    [[ -n "${share}" ]] || { echo "mount ${path}: share is required"; return 1; }
    parsed="$(nfs_parse_share_ref "${share}" 2>&1)" || { echo "mount ${path}: ${parsed}"; return 1; }
    read -r kind host name <<< "${parsed}"
    if [[ "${kind}" == "literal" ]]; then
        if nfs_is_instance "${host}"; then
            echo "mount ${path}: ${host} is a module instance — name its share (${host}:<name>), a path would go around the grant"
            return 1
        fi
        nfs_check_path "${consumer}" "${m}" || bad=1
        return "${bad}"
    fi
    if ! nfs_is_instance "${host}"; then
        echo "mount ${path}: ${host} is not a module instance (no config/${host}.json) — for an unmodelled server write ${host}:/<path>"
        return 1
    fi
    if ! nfs_export "${host}" "${name}" >/dev/null; then
        echo "mount ${path}: ${host} declares no export '${name}' — add it to config/${host}.json nfs.exports[] (a consumer never creates an export, ADR-029 D11)"
        return 1
    fi
    grant="$(nfs_grant_for "${host}" "${name}" "${consumer}")"
    if [[ -z "${grant}" ]]; then
        echo "mount ${path}: ${host}:${name} grants ${consumer} nothing — add {\"consumer\": \"${consumer}\", \"access\": \"${access}\"} to its grants"
        return 1
    fi
    if [[ "${access}" == "rw" && "${grant}" == "ro" ]]; then
        echo "mount ${path}: asks rw, but ${host}:${name} grants ${consumer} only ro"
        return 1
    fi
    nfs_check_path "${consumer}" "${m}" || bad=1
    return "${bad}"
}

# nfs_check_path <consumer> <mount-json> — a server behind the firewall needs the
# rule network:rules derives from the mounts; without that service there is none,
# and the mount would hang instead of failing.
nfs_check_path() {
    local consumer="$1" m="$2"
    nfs_mount_crosses_zone "${consumer}" "${m}" || return 0
    nfs_wires_rules "${consumer}" && return 0
    echo "mount $(jq -r .path <<< "${m}"): $(jq -r .share <<< "${m}") is reached through the firewall — ${consumer} must depend on network:rules, which derives the tcp/2049 rule from its mounts (ADR-029 D5)"
    return 1
}

# nfs_mount_crosses_zone <consumer> <mount-json> — rc 0 when the mount's server is
# reached through the firewall (ADR-029 D5 layer 2): a module instance in another
# zone, or an unmodelled server (whose zone TAPPaaS cannot know). The rule itself
# is derived by rules-manager from the same mounts (nfs_derived_egress).
nfs_mount_crosses_zone() {
    local consumer="$1" m="$2" kind host name czone szone
    read -r kind host name < <(nfs_parse_share_ref "$(jq -r '.share // empty' <<< "${m}")" 2>/dev/null) || return 1
    [[ "${kind}" == "literal" ]] && return 0
    nfs_is_instance "${host}" || return 1
    czone="$(jq -r '.zone0 // ""' "${NFS_CONFIG_DIR}/${consumer}.json" 2>/dev/null)"
    szone="$(jq -r '.zone0 // ""' "${NFS_CONFIG_DIR}/${host}.json" 2>/dev/null)"
    [[ "${czone}" != "${szone}" ]]
}

# nfs_wires_rules <consumer> — rc 0 when the consumer has network:rules, the
# service that compiles its firewall path.
nfs_wires_rules() {
    jq -e '((.dependsOn // []) + (.integratesWith // [])) | any(. == "network:rules" or . == "firewall:rules")' \
        "${NFS_CONFIG_DIR}/$1.json" >/dev/null 2>&1
}
