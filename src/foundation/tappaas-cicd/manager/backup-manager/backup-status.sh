#!/usr/bin/env bash
# backup-status.sh — backup status for every deployed module (ADR-007 P9).
#
# Reads CONFIG_DIR module JSONs + site.json + environments/, resolves the
# effective backup policy via the cascade lib, and prints one compact JSON
# object per module: module, environment, enabled, retention, residency,
# inPbsJob (declares dependsOn backup:vm). Read-only; never contacts PBS.
#
# Options:
#   --config-dir DIR   config directory (default $CONFIG_DIR or /home/tappaas/config)
#   --json             machine output: a JSON array of all module policies
#   --disabled-only    only modules with backup disabled
#   -h, --help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-cascade.sh
. "${HERE}/lib-cascade.sh"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; 1d'; }

JSON_OUT=0
DISABLED_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir) CONFIG_DIR="$2"; CASCADE_CONFIG_DIR="$2"; export CONFIG_DIR; shift 2 ;;
        --json) JSON_OUT=1; shift ;;
        --disabled-only) DISABLED_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Collect each module's effective policy + PBS-job wiring into one JSON array.
collect() {
    local module pol injob
    local first=1
    printf '['
    while IFS= read -r module; do
        [[ -n "$module" ]] || continue
        pol="$(bc_resolve "$module")" || continue
        if bc_module_in_pbs_job "$module"; then injob=true; else injob=false; fi
        if [[ "$DISABLED_ONLY" -eq 1 ]]; then
            [[ "$(jq -r '.enabled' <<<"$pol")" == "false" ]] || continue
        fi
        pol="$(jq -c --argjson j "$injob" '. + {inPbsJob: $j}' <<<"$pol")"
        [[ $first -eq 1 ]] || printf ','
        first=0
        printf '%s' "$pol"
    done < <(bc_list_modules)
    printf ']'
}

arr="$(collect)"

if [[ "$JSON_OUT" -eq 1 ]]; then
    jq '.' <<<"$arr"
    exit 0
fi

# Human-readable table.
n="$(jq 'length' <<<"$arr")"
if [[ "$n" -eq 0 ]]; then
    echo "No deployed modules found in ${CASCADE_CONFIG_DIR}"
    exit 0
fi
printf '%-28s %-12s %-8s %-10s %-9s %s\n' MODULE ENVIRONMENT ENABLED RETENTION RESIDENCY IN-PBS-JOB
jq -r '.[] | [
    .module,
    (.environment // "-"),
    (.enabled|tostring),
    .retention,
    .residency,
    (.inPbsJob|tostring)
  ] | @tsv' <<<"$arr" \
| while IFS=$'\t' read -r m e en ret res job; do
    printf '%-28s %-12s %-8s %-10s %-9s %s\n' "$m" "$e" "$en" "$ret" "$res" "$job"
  done
