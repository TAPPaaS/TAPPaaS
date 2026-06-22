#!/usr/bin/env bash
#
# validate.sh — validate a zones.json against structural + reference integrity.
#
# Managers ship validate.sh (controllers do not). network-manager owns zones.json,
# so this checks the desired-state document is well-formed before any reconcile:
#   - valid JSON
#   - every real zone (non-"_" key with a state/vlantag) has the required fields
#   - VLAN tags are unique
#   - every name in any zone's access-to / pinhole-allowed-from references a
#     known zone or the synthetic "internet" pseudo-zone
#
# Usage: validate.sh [<zones.json>]   (default: $TAPPAAS_CONFIG/zones.json)
# Exit non-zero on any violation.
set -euo pipefail

ZONES="${1:-${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json}"

command -v jq >/dev/null 2>&1 || { echo "validate: jq is required" >&2; exit 1; }
[[ -f "${ZONES}" ]] || { echo "validate: zones.json not found: ${ZONES}" >&2; exit 1; }
jq empty "${ZONES}" 2>/dev/null || { echo "validate: not valid JSON: ${ZONES}" >&2; exit 1; }

errs=0
err() { echo "  VALIDATION: $*" >&2; errs=$((errs + 1)); }

# Real zones = keys not starting with "_" that carry a state or vlantag.
mapfile -t zones < <(jq -r 'to_entries[] | select(.key|startswith("_")|not) | select(.value.state? or .value.vlantag?) | .key' "${ZONES}")

# Required fields per zone.
for z in "${zones[@]}"; do
    for field in state vlantag type; do
        if [[ "$(jq -r --arg z "${z}" --arg f "${field}" '.[$z][$f] // "MISSING"' "${ZONES}")" == "MISSING" ]]; then
            err "zone '${z}' missing required field '${field}'"
        fi
    done
done

# VLAN uniqueness.
dupes="$(jq -r '[to_entries[] | select(.key|startswith("_")|not) | .value.vlantag // empty] | group_by(.) | map(select(length>1) | .[0]) | .[]' "${ZONES}")"
if [[ -n "${dupes}" ]]; then
    while read -r v; do [[ -n "${v}" ]] && err "duplicate VLAN tag ${v}"; done <<<"${dupes}"
fi

# Reference integrity: access-to / pinhole-allowed-from must name a known zone
# (or "internet").
known=$(printf '%s\n' "${zones[@]}" "internet")
for z in "${zones[@]}"; do
    for key in "access-to" "pinhole-allowed-from"; do
        mapfile -t refs < <(jq -r --arg z "${z}" --arg k "${key}" '(.[$z][$k] // [])[]' "${ZONES}")
        for r in "${refs[@]}"; do
            [[ -z "${r}" ]] && continue
            grep -qxF "${r}" <<<"${known}" || err "zone '${z}'.${key} references unknown zone '${r}'"
        done
    done
done

if [[ "${errs}" -eq 0 ]]; then
    echo "validate: ok (${#zones[@]} zones, ${ZONES})"
    exit 0
fi
echo "validate: ${errs} error(s) in ${ZONES}" >&2
exit 1
