#!/usr/bin/env bash
# shellcheck shell=bash
#
# storage-placement.sh — which storage a new guest is built on (ADR-037 D1).
# Sourced by Create-TAPPaaS-VM.sh and Create-TAPPaaS-LXC.sh on the node; the
# decision functions are pure (lists in, a name out), so
# test-storage-placement.sh drives them without Proxmox.
#
# A module's `storage` is a preference, not a requirement. The guest goes to
# the storage its config names when the node has it; otherwise to the first the
# node has of: a pool of the same class with another number (tanka2 for
# tanka1), any tanka<N>, any other ZFS pool (tankc1, a pool named otherwise),
# the boot pool (local-zfs, rpool/data) — the last only
# while the guest leaves it 20 % free, since the node's root filesystem lives in
# the same pool. The move is a warning; the mothership records the storage used
# in the module's config (cluster/services/vm/install-service.sh).

# sp_choose <want> <image-pools> <zfs-pools> <boot-storage>
# Prints the storage to build on; returns 1 when the node has none of them.
# <image-pools>/<zfs-pools>: newline-separated storage names that can hold a
# guest (all of them / the zfspool ones); <boot-storage>: the storage on
# rpool/data, or empty.
sp_choose() {
    local want="$1" pools="$2" zfs="$3" boot="$4" class c
    if printf '%s\n' "${pools}" | grep -qxF -- "${want}"; then printf '%s' "${want}"; return 0; fi
    # The same class with another number: tanka1 → tanka2.
    if [[ "${want}" =~ ^(tank[a-z])[0-9]+$ ]]; then
        class="${BASH_REMATCH[1]}"
        c="$(printf '%s\n' "${zfs}" | grep -xE "${class}[0-9]+" | sort -V | head -1)"
        [[ -n "${c}" ]] && { printf '%s' "${c}"; return 0; }
    fi
    # Any tanka<N>.
    c="$(printf '%s\n' "${zfs}" | grep -xE 'tanka[0-9]+' | sort -V | head -1)"
    [[ -n "${c}" ]] && { printf '%s' "${c}"; return 0; }
    # Any other ZFS data pool: a node that has one keeps its guests off the boot disk.
    c="$(printf '%s\n' "${zfs}" | grep -vxF -- "${boot:-}" | grep -v '^$' | sort -V | head -1)"
    [[ -n "${c}" ]] && { printf '%s' "${c}"; return 0; }
    # The boot pool.
    if [[ -n "${boot}" ]] && printf '%s\n' "${zfs}" | grep -qxF -- "${boot}"; then
        printf '%s' "${boot}"; return 0
    fi
    return 1
}

# sp_size_bytes <size> — a Proxmox size (8G, 512M, 1T, or bytes) in bytes.
sp_size_bytes() {
    local s="${1^^}" n
    n="${s%[KMGT]}"; n="${n%B}"
    [[ "${n}" =~ ^[0-9]+$ ]] || { echo 0; return; }
    case "${s}" in
        *T) echo $(( n * 1024 ** 4 )) ;;
        *G) echo $(( n * 1024 ** 3 )) ;;
        *M) echo $(( n * 1024 ** 2 )) ;;
        *K) echo $(( n * 1024 )) ;;
        *)  echo "${n}" ;;
    esac
}

# sp_reserve_ok <pool-size-bytes> <pool-alloc-bytes> <guest-bytes> — 0 when the
# pool keeps at least 20 % free with the guest's disk on it.
sp_reserve_ok() {
    local size="$1" alloc="$2" guest="$3"
    (( size > 0 )) || return 1
    (( (alloc + guest) * 100 <= size * 80 ))
}

# ── on the node ───────────────────────────────────────────────────────

# sp_boot_storage — the storage whose pool is rpool/data (local-zfs on a
# stock ZFS install), or nothing.
sp_boot_storage() {
    awk '$1=="zfspool:" {id=$2; next} id && $1=="pool" && $2=="rpool/data" {print id; exit} /^[^ \t]/ {id=""}' \
        "${SP_STORAGE_CFG:-/etc/pve/storage.cfg}" 2>/dev/null || true
}

# sp_dataset <storage> — the ZFS dataset a zfspool storage stands for
# (local-zfs → rpool/data, tanka1 → tanka1); the name itself when unknown.
sp_dataset() {
    local d
    d="$(awk -v s="$1" '$1 ~ /:$/ {id=($2 == s)} id && $1=="pool" {print $2; exit}' \
        "${SP_STORAGE_CFG:-/etc/pve/storage.cfg}" 2>/dev/null || true)"
    printf '%s' "${d:-$1}"
}
