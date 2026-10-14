#!/usr/bin/env bash
#
# disk-grow-lib.sh — the decisions behind automatic disk growth (#100).
#
# Pure: every input is an argument, nothing is read from the cluster or a
# guest, so the rules are tested without one (cluster/test.sh). The caller —
# services/vm/auto-grow.sh — gathers the facts and acts on the answer.
#
#   dg_size_gb <size>                  "24G" → 24, "512M" → 1, "2T" → 2048
#   dg_decide <used%> <size-gb> <threshold%> <grow%> <min-gb> <max-gb|0>
#       prints the new size in GB; rc 0 grow, 1 not needed, 2 already at the cap
#   dg_pool_room <total-kib> <used-kib> <avail-kib> <increase-gb> <ceiling%>
#       prints the pool's use after the grow in %; rc 0 room, 1 none

# Whole GB, rounded up: a size is never made smaller by converting it.
dg_size_gb() {
    local s="$1" n u
    n="${s%[KMGTkmgt]}"; u="${s:${#n}}"
    [[ "${n}" =~ ^[0-9]+$ ]] || return 1
    case "${u^^}" in
        T)  echo $(( n * 1024 )) ;;
        G|"") echo "${n}" ;;
        M)  echo $(( (n + 1023) / 1024 )) ;;
        K)  echo $(( (n + 1048575) / 1048576 )) ;;
    esac
}

# Grow when the guest's / is at or over the threshold: by grow% of the current
# size, at least min-gb, never past max-gb (0 = no cap).
dg_decide() {
    local used="$1" cur="$2" threshold="$3" growpct="$4" min="$5" max="${6:-0}" inc new
    (( used >= threshold )) || return 1
    inc=$(( (cur * growpct + 99) / 100 ))
    (( inc < min )) && inc="${min}"
    new=$(( cur + inc ))
    if (( max > 0 && new > max )); then
        (( cur >= max )) && { echo "${cur}"; return 2; }
        new="${max}"
    fi
    echo "${new}"
}

# Room on a pool for a grow: the increase must fit in what the pool has free
# (avail already counts reservations), and the pool must stay at or below the
# ceiling afterwards — ZFS slows down sharply as a pool fills.
dg_pool_room() {
    local total="$1" used="$2" avail="$3" inc_gb="$4" ceiling="$5" inc_kib after
    (( total > 0 )) || { echo 100; return 1; }
    inc_kib=$(( inc_gb * 1048576 ))
    after=$(( ( (used + inc_kib) * 100 + total - 1 ) / total ))
    echo "${after}"
    (( inc_kib <= avail && after <= ceiling ))
}
