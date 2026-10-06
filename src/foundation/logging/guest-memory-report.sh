#!/usr/bin/env bash
#
# guest-memory-report.sh — what each guest needed over a window, from the
# samples node/tappaas-guest-memory sends to Loki once a minute (#663).
#
# Usage: guest-memory-report.sh [window]     (default 7d; any LogQL range: 24h, 7d, 14d)
#        LOKI_URL=http://logging.mgmt.internal:3100 (default)
#
# Columns, in GiB: declared (the VM's memory), peak / p99 / avg of `used`
# (total - MemAvailable: what the guest could not give back), the suggested
# size, and the pressure seen: peak PSI some-avg60, allocation stalls during the
# window (the rise of the guest's counter; a reboot inside it can overstate
# this, never hide it) and the OOM kills counted since the guest's boot.
# `cover` is how much of the window has samples — a guest added, moved off a
# node or stopped part-way reads below 100%.
#
# Suggested size — the method #663 asks to have written down:
#   peak + max(25 %, 0.5 GiB), rounded up to 0.5 GiB, never below 1 GiB.
# Peak, not p99: a guest sized below its peak is reclaiming or swapping at
# exactly the moment it is busiest. The margin covers what one window did not
# see. A guest with pressure (PSI > 0, stalls or an OOM kill) keeps at least what it
# has: its peak was capped by its size, so the peak understates its need.
set -euo pipefail
# Loki's API takes the admin credential (#165 §1): log_shipping_curl_admin.
# shellcheck source=../tappaas-cicd/lib/log-shipping.sh
. "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"

WINDOW="${1:-7d}"
LOKI_URL="${LOKI_URL:-http://logging.mgmt.internal:3100}"
SEL='{source="proxmox", unit="tappaas-guest-memory"} | logfmt | measured="1" | __error__=""'

q() {   # q <logql> — instant query → {"vm": value, …}
    log_shipping_curl_admin -fsS --max-time 120 -G "${LOKI_URL}/loki/api/v1/query" --data-urlencode "query=$1" \
        | jq -c '[.data.result[] | {key: .metric.vm, value: (.value[1] | tonumber)}] | from_entries'
}

case "${WINDOW}" in
    *d) secs=$(( ${WINDOW%d} * 86400 )) ;;
    *h) secs=$(( ${WINDOW%h} * 3600 )) ;;
    *)  echo "window must be <n>d or <n>h" >&2; exit 2 ;;
esac

declared="$(q "max by (vm) (max_over_time(${SEL} | unwrap maxmem [${WINDOW}]))")"
peak="$(q "max by (vm) (max_over_time(${SEL} | unwrap used [${WINDOW}]))")"
p99="$(q "max by (vm) (quantile_over_time(0.99, ${SEL} | unwrap used [${WINDOW}]))")"
avg="$(q "avg by (vm) (avg_over_time(${SEL} | unwrap used [${WINDOW}]))")"
psi="$(q "max by (vm) (max_over_time(${SEL} | unwrap psi_some_avg60 [${WINDOW}]))")"
oom="$(q "max by (vm) (max_over_time(${SEL} | unwrap oom_kills [${WINDOW}]))")"
stall_hi="$(q "max by (vm) (max_over_time(${SEL} | unwrap alloc_stalls [${WINDOW}]))")"
stall_lo="$(q "min by (vm) (min_over_time(${SEL} | unwrap alloc_stalls [${WINDOW}]))")"
count="$(q "sum by (vm) (count_over_time(${SEL} [${WINDOW}]))")"

printf 'Guest memory over %s (Loki: %s)\n\n' "${WINDOW}" "${LOKI_URL}"
jq -rn --argjson d "${declared}" --argjson pk "${peak}" --argjson p "${p99}" --argjson a "${avg}" \
       --argjson s "${psi}" --argjson o "${oom}" --argjson c "${count}" --argjson w "${secs}" \
       --argjson sh "${stall_hi}" --argjson sl "${stall_lo}" '
    def gib: . / 1073741824;
    def r2: . * 100 | round / 100;
    def up_half: (. * 2 | ceil) / 2;
    ["vm", "declared", "peak", "p99", "avg", "suggest", "psi", "stalls", "oom", "cover"],
    ($d | keys[] as $vm | ($pk[$vm] // 0 | gib) as $peak | ($d[$vm] | gib) as $dec
      | ([$peak * 1.25, $peak + 0.5] | max | up_half | [., 1] | max) as $sug
      | ((($sh[$vm] // 0) - ($sl[$vm] // 0)) | if . < 0 then 0 else . end) as $st
      | (if (($s[$vm] // 0) > 0 or $st > 0 or ($o[$vm] // 0) > 0) and $sug < $dec then $dec else $sug end) as $sug
      | [$vm, ($dec | r2), ($peak | r2), ($p[$vm] // 0 | gib | r2), ($a[$vm] // 0 | gib | r2), $sug,
         ($s[$vm] // 0), $st, ($o[$vm] // 0), ((($c[$vm] // 0) * 60 / $w * 100 | round | tostring) + "%")])
    | @tsv' | column -t -s $'\t'
