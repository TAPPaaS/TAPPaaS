#!/usr/bin/env bash
# nfs-lib.sh — the parts of storage:nfs (ADR-029 v0.9) that need no server and no
# guest: reading a share reference, looking a share up in config/shares.json,
# checking share declarations and mounts, and rendering an export's `sharenfs`.
# Pure functions over config/ JSON, so the fast tier can test them
# (test-nfs-lib.sh). The same rules, reported by storage-manager and
# `module-manager validate`, live in lib/ts/src/nfs-shares.ts; keep them in step.
#
# Used by the storage module's service (storage:nfs) and by every server's NFS
# hook (pvehost/storage/nfs-server.sh), which find it through config/storage.json.
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
# ADR-029 D2b (v0.8): every node mounts an export here, whatever the pool, and
# every share is reached as nfs-<share>.<domain> — so a share can move between
# nodes and pools without a consumer noticing.
NFS_MOUNT_ROOT="/tappaas-nfs"
NFS_ALIAS_DOMAIN="mgmt.internal"
NFS_NAME_RE='^[a-z][a-z0-9-]*$'
# The consumer coordinate (ADR-029 v0.9 D1) and the Site file shares live in (D18).
NFS_COORDINATE="storage:nfs"
nfs_shares_file() { printf '%s/shares.json\n' "${NFS_CONFIG_DIR}"; }

# nfs_parse_share_ref <ref> — ADR-029 D2 (v0.8). Prints one line:
#   named <share>              a share name, Site-unique
#   literal <host> <path>      contains ':' — an unmodelled server's path
# rc 1 (and a reason on stderr) for anything else.
nfs_parse_share_ref() {
    local ref="$1" host rest
    if [[ "${ref}" == *:* ]]; then
        host="${ref%%:*}"; rest="${ref#*:}"
        [[ -n "${host}" && "${rest}" == /* ]] \
            || { echo "share '${ref}' is not <ip-or-host>:/<path> — a share is named, or a literal with an absolute path" >&2; return 1; }
        printf 'literal %s %s\n' "${host}" "${rest}"
        return 0
    fi
    [[ "${ref}" =~ ${NFS_NAME_RE} ]] || { echo "share name '${ref}' must match ${NFS_NAME_RE}" >&2; return 1; }
    printf 'named %s\n' "${ref}"
}

# nfs_share_alias <share> — the DNS name a share is reached by (D2b).
nfs_share_alias() { printf 'nfs-%s.%s\n' "$1" "${NFS_ALIAS_DOMAIN}"; }

# nfs_is_instance <name> — rc 0 when config/<name>.json exists: a module instance
# TAPPaaS knows (ADR-026 D6.1).
nfs_is_instance() { [[ -f "${NFS_CONFIG_DIR}/$1.json" ]]; }

# nfs_instance_managed <instance> — rc 0 when the instance is a managed Host
# whose exports TAPPaaS builds; rc 1 for a registered, unmanaged server.
nfs_instance_managed() {
    [[ "$(jq -r '.management // "managed"' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null)" == "managed" ]]
}

# nfs_shares — every declared share as compact JSON, its name included as .name,
# one per line. An absent shares.json is an empty one (D18).
nfs_shares() {
    local f; f="$(nfs_shares_file)"
    [[ -f "${f}" ]] || return 0
    jq -c '.nfs.shares // {} | to_entries[] | .value + {name: .key}' "${f}" 2>/dev/null
}

# nfs_exports <instance> — the shares declared for that server, compact JSON, one per
# line — what its hook builds (D19).
nfs_exports() { nfs_shares | jq -c --arg i "$1" 'select(.server == $i)'; }

# nfs_export <instance> <name> — one share's declaration if that server carries it;
# rc 1 otherwise.
nfs_export() {
    nfs_shares | jq -ce --arg i "$1" --arg n "$2" 'select(.server == $i and .name == $n)' | grep . || return 1
}

# nfs_share <name> — one share's declaration, wherever it lives; rc 1 when undeclared.
nfs_share() { nfs_shares | jq -ce --arg n "$1" 'select(.name == $n)' | grep . || return 1; }

# nfs_find_share <share> — the server carrying it; rc 1 when no share of that name is
# declared (a pending mount, D11). Names are unique by construction: shares.json is a
# map keyed by name.
nfs_find_share() {
    local s; s="$(nfs_share "$1")" || return 1
    jq -r '.server // empty' <<< "${s}" | grep . || return 1
}

# nfs_dataset <pool> <name> — the dataset an export lives in.
nfs_dataset() { printf '%s/%s/%s\n' "$1" "${NFS_PARENT}" "$2"; }

# nfs_export_path <instance> <export-json> — the path inside the server a consumer
# mounts: the uniform mountpoint on a node, the descriptor's own path on a NAS.
nfs_export_path() {
    if nfs_instance_managed "$1"; then
        printf '%s/%s\n' "${NFS_MOUNT_ROOT}" "$(jq -r .name <<< "$2")"
    else
        jq -r .path <<< "$2"
    fi
}

# nfs_check_export <share-json> <managed|unmanaged> — ADR-029 D4 / D2a: one share
# declaration's shape (its .name included). Prints one problem per line; rc 1 when
# there is any. Whether the pool exists is a question for the server.
nfs_check_export() {
    local e="$1" mode="$2"
    jq -r --arg mode "${mode}" --arg re "${NFS_NAME_RE}" --argjson min "${NFS_OWNER_MIN}" --argjson max "${NFS_OWNER_MAX}" '
      (.name // "<unnamed>") as $nm |
      [
        (if (.name | type) != "string" or (.name | test($re) | not)
           then "share \($nm): name must match \($re)" else empty end),
        (if (.server | type) != "string" or .server == "" then "share \($nm): server is required" else empty end),
        (if has("grants") and (.grants | type) != "object" then "share \($nm): grants must be a map of consumer to ro|rw"
         else (.grants // {} | to_entries[] | select(.value != "ro" and .value != "rw")
               | "share \($nm): grant for \(.key) is \(.value) (ro|rw)") end),
        (if $mode == "managed" then
           (if (.pool | type) != "string" or .pool == "" then "share \($nm): pool is required on a managed Host" else empty end),
           (if has("path") then "share \($nm): path is for a registered, unmanaged server — a managed Host builds the dataset from pool" else empty end),
           (if (.backup.enabled | type) != "boolean"
              then "share \($nm): backup.enabled must be stated, true or false (ADR-029 D9 — there is no default)" else empty end),
           (if has("owner") and ((.owner.uid | type) != "number" or (.owner.gid | type) != "number"
                                 or .owner.uid < $min or .owner.uid > $max or .owner.gid < $min or .owner.gid > $max)
              then "share \($nm): owner must be {uid, gid} in \($min)-\($max)" else empty end),
           (.properties // {} | keys[] | select(IN("recordsize", "compression", "atime") | not)
              | "share \($nm): property \(.) is not one TAPPaaS sets (recordsize, compression, atime)")
         else
           (if (.path | type) != "string" or (.path | startswith("/") | not)
              then "share \($nm): path (absolute) is required on a registered, unmanaged server" else empty end),
           (["pool", "quota", "owner", "properties", "backup"][] as $k | select(has($k))
              | "share \($nm): \($k) is not allowed on a registered, unmanaged server — TAPPaaS does not provision it"),
           (if ((.version // "4.2") | IN("4.2", "4.1", "4.0", "3") | not)
              then "share \($nm): version \(.version) (4.2|4.1|4.0|3)" else empty end),
           (if (.version // "4.2") == "3" and ((.v3Ports.mountd | type) != "number"
                 or (.v3Ports.nlockmgr | type) != "number" or (.v3Ports.statd | type) != "number")
              then "share \($nm): NFSv3 needs v3Ports {mountd, nlockmgr, statd} pinned — dynamic ports cannot be firewalled per host" else empty end)
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

# nfs_grant_for <share> <consumer> — the access a consumer is granted on a share
# ("ro"/"rw"), empty when it has none.
nfs_grant_for() {
    local s; s="$(nfs_share "$1")" || return 0
    jq -r --arg c "$2" '.grants[$c] // empty' <<< "${s}"
}

# nfs_mounts <consumer> — the consumer's config."storage:nfs".mounts[], compact, one per line.
nfs_mounts() { jq -c --arg k "${NFS_COORDINATE}" '.config[$k].mounts // [] | .[]' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null; }

# nfs_mounts_share <consumer> <share> — rc 0 when one of the consumer's mounts names
# the share. Only such a consumer earns a client-list entry (D16).
nfs_mounts_share() {
    jq -e --arg s "$2" --arg k "${NFS_COORDINATE}" 'any(.config[$k].mounts // [] | .[]; .share == $s)' \
        "${NFS_CONFIG_DIR}/$1.json" >/dev/null 2>&1
}

# nfs_mount_status <mount-json> — after nfs_check_mount passed: "literal", "pending"
# (no server declares the share, D11) or "available <instance>".
nfs_mount_status() {
    local kind name server
    read -r kind name _ < <(nfs_parse_share_ref "$(jq -r .share <<< "$1")" 2>/dev/null) || return 1
    [[ "${kind}" == "literal" ]] && { echo literal; return 0; }
    if server="$(nfs_find_share "${name}" 2>/dev/null)"; then echo "available ${server}"; else echo pending; fi
}

# nfs_check_mount <consumer> <mount-json> — ADR-029 D3, D11 (v0.8): the mount's own
# shape and, for a named share that exists, the two-key check against it. A share no
# server declares is NOT a problem: the mount is pending. Prints one problem per
# line; rc 1 when there is any.
nfs_check_mount() {
    local consumer="$1" m="$2" path share access subdir parsed kind name host lpath server grant bad=0
    path="$(jq -r '.path // empty' <<< "${m}")"
    share="$(jq -r '.share // empty' <<< "${m}")"
    access="$(jq -r '.access // "ro"' <<< "${m}")"
    subdir="$(jq -r '.subdir // empty' <<< "${m}")"
    case "${path}" in
        "") echo "mount: path is required"; bad=1 ;;
        /|/nix|/nix/*|/etc|/etc/*|/var|/boot|/boot/*|/proc*|/sys*|/dev*|/run*|/usr|/usr/*|/bin*|/sbin*|/lib*)
            echo "mount ${path}: not a directory a share may cover"; bad=1 ;;
        /*) ;;
        *) echo "mount ${path}: path must be absolute"; bad=1 ;;
    esac
    [[ "${access}" == "ro" || "${access}" == "rw" ]] || { echo "mount ${path}: access ${access} (ro|rw)"; bad=1; }
    if [[ -n "${subdir}" ]]; then
        if [[ "${subdir}" == /* || "/${subdir}/" == *"/../"* || "/${subdir}/" == *"/./"* || ! "${subdir}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
            echo "mount ${path}: subdir '${subdir}' must be a relative path inside the share — no leading /, no . or .. (ADR-029 D15)"; bad=1
        fi
    fi
    jq -e '(.stopUnits // []) | type == "array" and all(.[]; type == "string")' <<< "${m}" >/dev/null 2>&1 \
        || { echo "mount ${path}: stopUnits must be a list of unit names"; bad=1; }
    [[ -n "${share}" ]] || { echo "mount ${path}: share is required"; return 1; }
    parsed="$(nfs_parse_share_ref "${share}" 2>&1)" || { echo "mount ${path}: ${parsed}"; return 1; }
    read -r kind name lpath <<< "${parsed}"
    if [[ "${kind}" == "literal" ]]; then
        host="${name}"
        if nfs_is_instance "${host}"; then
            echo "mount ${path}: ${host} is a module instance — name its share, a literal path would go around the grant (ADR-029 D2)"
            return 1
        fi
        if nfs_is_public_ipv4 "${host}"; then
            echo "mount ${path}: ${host} is a public address — NFS with sec=sys is cleartext and trusts the client's UID; only a server on the site's own or a private routed network is mounted (ADR-029 D2a)"
            return 1
        fi
        nfs_check_path "${consumer}" "${m}" || bad=1
        return "${bad}"
    fi
    server="$(nfs_find_share "${name}")" || return "${bad}"    # pending: not a problem (D11)
    if [[ "$(jq -r '.zone0 // ""' "${NFS_CONFIG_DIR}/${server}.json")" == "wan" ]]; then
        echo "mount ${path}: share ${name} is on ${server}, in the wan zone — NFS is never mounted across it (ADR-029 D2a)"
        return 1
    fi
    grant="$(nfs_grant_for "${name}" "${consumer}")"
    if [[ -z "${grant}" ]]; then
        echo "mount ${path}: share ${name} grants ${consumer} nothing — run: storage-manager nfs grant ${name} ${consumer} ${access}  (or remove the mount, ADR-029 D11)"
        return 1
    fi
    if [[ "${access}" == "rw" && "${grant}" == "ro" ]]; then
        echo "mount ${path}: asks rw, but share ${name} grants ${consumer} only ro"
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
    echo "mount $(jq -r .path <<< "${m}"): share $(jq -r .share <<< "${m}") is reached through the firewall — ${consumer} must depend on network:rules, which derives the tcp/2049 rule from its mounts (ADR-029 D5)"
    return 1
}

# nfs_mount_crosses_zone <consumer> <mount-json> — rc 0 when the mount's server is
# reached through the firewall (D5 layer 2): a server in another zone, or an
# unmodelled one (whose zone TAPPaaS cannot know). A pending mount crosses nothing.
nfs_mount_crosses_zone() {
    local consumer="$1" m="$2" kind name server czone szone
    read -r kind name _ < <(nfs_parse_share_ref "$(jq -r '.share // empty' <<< "${m}")" 2>/dev/null) || return 1
    [[ "${kind}" == "literal" ]] && return 0
    server="$(nfs_find_share "${name}" 2>/dev/null)" || return 1
    czone="$(jq -r '.zone0 // ""' "${NFS_CONFIG_DIR}/${consumer}.json" 2>/dev/null)"
    szone="$(jq -r '.zone0 // ""' "${NFS_CONFIG_DIR}/${server}.json" 2>/dev/null)"
    [[ "${czone}" != "${szone}" ]]
}

# nfs_wires_rules <consumer> — rc 0 when the consumer has network:rules, the
# service that compiles its firewall path.
nfs_wires_rules() {
    jq -e '((.dependsOn // []) + (.integratesWith // [])) | any(. == "network:rules" or . == "firewall:rules")' \
        "${NFS_CONFIG_DIR}/$1.json" >/dev/null 2>&1
}

# nfs_is_public_ipv4 <host> — rc 0 for a literal IPv4 outside the private, CGNAT,
# loopback and link-local ranges (ADR-029 D2a). A name is not judged here.
# Mirrors isPublicIpv4 in module-manager/src/nfs.ts.
nfs_is_public_ipv4() {
    local a b
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    (( a == 10 || a == 127 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    return 0
}
