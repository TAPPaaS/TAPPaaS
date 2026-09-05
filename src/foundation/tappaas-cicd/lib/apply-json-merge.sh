#!/usr/bin/env bash
#
# apply-json-merge.sh — 3-way module-config reconciliation (#207).
#
# Background: when a module's release source JSON is updated upstream, we want
# to adopt those release changes for fields the operator hasn't touched, while
# preserving fields the operator has customized in the installed copy.
#
# The 3-way inputs:
#
#   current = ${CONFIG_DIR}/<eff>.json        (the live config; may have operator edits)
#   orig    = ${CONFIG_DIR}/<eff>.json.orig   (snapshot of the source at last install/upgrade)
#   source  = <module_dir>/<base>.json        (the new release source)
#
# Per-leaf rule:
#
#   1. If path[0] in AUTO_FIELDS (location, installTime, updateTime,
#      releaseDate, variant):                                keep current
#   2. Else if path absent in source, present in current:
#        2a. …and present in orig:                           DROP (#581)
#            The release once defined it and no longer does — the author
#            removed the field, so the deployed config must follow. Reported
#            with the discarded value.
#        2b. …and absent from orig:                          keep current
#            Never in the release, so it is operator-added (or an .orig that
#            predates the field) — the case this rule exists to protect.
#   3. Else if path absent in current:                       adopt source
#   4. Else if current == orig:                              adopt source
#   5. Else:                                                 keep current (pinned)
#
# Arrays are compared whole — if the operator touched the array at all, the
# whole array is pinned. (Documented limitation; revisit when a real module
# needs path-level array merge.)
#
# All three sides are NORMALIZED TO FLAT before comparing, so the merge is
# invariant under refactors that move fields between top-level and the Pattern
# A `config` block. The output is rendered in canonical Pattern A form via
# `regroup_to_pattern_a` (sourced from convert-json-to-config.sh).
#
# On first run after this script is deployed, ${CONFIG_DIR}/<eff>.json.orig
# may not exist. We backfill it as `cp source → orig`, so existing operator
# customizations remain pinned (current != orig wherever the operator diverged
# from release).
#
# Usage:
#   apply-json-merge.sh <effective-module>
#
# Sourceable:
#   . /home/tappaas/bin/apply-json-merge.sh
#   apply_three_way_merge <effective-module> <module-dir>
#
# Exit codes:
#   0  merge applied (or no-op)
#   1  bad inputs / IO failure
#   2  bad arguments
#

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Guard against double-sourcing: readonly fails the second time.
if [[ -z "${_MERGE_CONFIG_DIR:-}" ]]; then
    readonly _MERGE_CONFIG_DIR="${TAPPAAS_MERGE_CONFIG_DIR:-/home/tappaas/config}"
    # Composed view (#567): definitions live per-service now. This file may be
    # sourced WITHOUT common-install-routines, so fall back to the cache path
    # rather than assuming the resolver is defined — and never to the raw
    # schemas/module-fields.json, which since #567 holds only the generic 19.
    readonly _MERGE_SCHEMA_FILE="$(declare -F tappaas_schema_file >/dev/null 2>&1 && tappaas_schema_file || printf %s "${TAPPAAS_SCHEMA_FILE:-${CONFIG_DIR:-/home/tappaas/config}/module-fields.json}")"
    # Header fields never merged — always preserve the installed value.
    # Note: vmname/vmid/etc are NOT in this list — operator changes there ARE
    # meaningful and follow the standard pin-vs-adopt rule.
    readonly _MERGE_AUTO_FIELDS='["location","installTime","updateTime","releaseDate","variant","environment"]'
fi

# Load common log functions if not already provided.
if ! declare -F info >/dev/null 2>&1; then
    info()  { echo "[Info] $*"; }
    warn()  { echo "[Warning] $*" >&2; }
    error() { echo "[Error] $*" >&2; }
    debug() { [[ "${TAPPAAS_DEBUG:-0}" -eq 1 ]] && echo "[Debug] $*" >&2 || true; }
    die()   { error "$@"; exit 1; }
fi

# Locate convert-json-to-config.sh — prefer the live ~/bin symlink, fall back
# to the repo location (useful when this is invoked before pre-update.sh has
# refreshed the symlinks).
#
# That repo location moved in the c2480cc reorg and this list was not updated,
# so the fallback pointed at nothing: it worked only while the symlink existed,
# which is the one situation it is not needed for (#570).
_merge_locate_converter() {
    local candidates=(
        "/home/tappaas/bin/convert-json-to-config.sh"
        "$(dirname "${BASH_SOURCE[0]}")/convert-json-to-config.sh"
        "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/manager/site-manager/convert-json-to-config.sh"
    )
    local p
    for p in "${candidates[@]}"; do
        if [[ -f "$p" ]]; then echo "$p"; return 0; fi
    done
    return 1
}

# Source the converter so `regroup_to_pattern_a` is available.
_merge_converter_path="$(_merge_locate_converter)" || {
    error "convert-json-to-config.sh not found — required for Pattern A rendering"
    exit 1
}
# shellcheck source=convert-json-to-config.sh disable=SC1090
. "${_merge_converter_path}"

# normalize_module_config may already be defined via common-install-routines;
# if not, define a local version (avoids hard dependency when called via cron).
if ! declare -F normalize_module_config >/dev/null 2>&1; then
    normalize_module_config() {
        jq '
            if (.config | type) == "object"
            then reduce (.config | to_entries[]) as $s (.; . * $s.value) | del(.config)
            else . end
        '
    }
fi

# Public function: 3-way merge for a single module.
#   $1 = effective module name (e.g. "openwebui" or "openwebui-staging")
#   $2 = module source directory (where <base>.json lives)
#
# Returns 0 on success, non-zero on failure. Writes the merged config to
# ${CONFIG_DIR}/<eff>.json and advances ${CONFIG_DIR}/<eff>.json.orig.
apply_three_way_merge() {
    local eff="${1:-}"
    local module_dir="${2:-}"

    if [[ -z "${eff}" || -z "${module_dir}" ]]; then
        error "apply_three_way_merge: usage <effective-module> <module-dir>"
        return 2
    fi
    if [[ ! -d "${module_dir}" ]]; then
        error "apply_three_way_merge: module directory not found: ${module_dir}"
        return 1
    fi

    local current="${_MERGE_CONFIG_DIR}/${eff}.json"
    local orig="${_MERGE_CONFIG_DIR}/${eff}.json.orig"

    if [[ ! -f "${current}" ]]; then
        error "apply_three_way_merge: installed config not found: ${current}"
        return 1
    fi

    # Determine the environment + base module name. .environment is the suffix
    # the effective name carries for a non-default environment (#438; was
    # .variant until the field was retired). Unsuffixed names — mgmt and the
    # default environment — strip to themselves, so this is a no-op there. The
    # filename heuristic below still covers installs that predate the field.
    local environment base
    environment="$(jq -r '.environment // ""' "${current}")"
    if [[ -n "${environment}" ]]; then
        base="${eff%-"${environment}"}"
    else
        base="${eff}"
    fi

    local source="${module_dir}/${base}.json"
    if [[ ! -f "${source}" ]]; then
        # Fallback for variant naming: try stripping suffix until a source matches.
        local try="${eff}"
        while [[ "${try}" == *-* ]]; do
            try="${try%-*}"
            if [[ -f "${module_dir}/${try}.json" ]]; then
                source="${module_dir}/${try}.json"
                base="${try}"
                break
            fi
        done
    fi
    if [[ ! -f "${source}" ]]; then
        error "apply_three_way_merge: source not found in ${module_dir} (tried ${base}.json and parent variants)"
        return 1
    fi
    if ! jq empty "${source}" 2>/dev/null; then
        error "apply_three_way_merge: source is not valid JSON: ${source}"
        return 1
    fi

    # Backfill missing .orig: use source as baseline so existing operator
    # customizations remain pinned (#207 decision: cp source → orig).
    local backfilled=0
    if [[ ! -f "${orig}" ]]; then
        info "  No .orig present — backfilling from source (operator customizations preserved)"
        cp "${source}" "${orig}"
        backfilled=1
    fi

    # Normalize all three to flat for comparison.
    local c_n o_n s_n
    c_n="$(normalize_module_config < "${current}")"
    o_n="$(normalize_module_config < "${orig}")"
    s_n="$(normalize_module_config < "${source}")"

    # Run the 3-way merge in jq. Inputs are passed as --argjson so this is one
    # process. Output is the merged flat JSON + a summary object with
    # ".adopted" / ".pinned" / ".added" / ".removed" counts and field lists
    # for logging.
    local merged_with_report
    merged_with_report="$(jq -n \
        --argjson c "${c_n}" \
        --argjson o "${o_n}" \
        --argjson s "${s_n}" \
        --argjson auto "${_MERGE_AUTO_FIELDS}" '
        # Collect every leaf path. "Leaf" = a path whose value is a scalar OR
        # an array. Objects are recursed into. Arrays are compared whole, so
        # paths inside arrays (containing a numeric segment) are excluded.
        def leaves:
            paths(type != "object")
            | select(all(.[]; type == "string"));

        # Union of leaf paths in c, o, s.
        ( ($c | [leaves]) + ($o | [leaves]) + ($s | [leaves]) | unique ) as $paths

        | reduce $paths[] as $p (
            { result: {}, adopted: [], pinned: [], added: [], kept: [], removed: [] };

            ($p[0]) as $top
            | (try ($c | getpath($p)) catch null) as $cv
            | ($c | getpath($p[0:1] | .) // null) as $_c_top   # detect presence
            | (try ($s | getpath($p)) catch null) as $sv
            | (try ($o | getpath($p)) catch null) as $ov

            | ($c | [paths] | map(. == $p) | any) as $in_c
            | ($s | [paths] | map(. == $p) | any) as $in_s
            | ($o | [paths] | map(. == $p) | any) as $in_o

            | if ($auto | index($top)) != null then
                # Rule 1: auto field — keep current value (if it exists).
                if $in_c then
                    .result = (.result | setpath($p; $cv))
                else . end
              elif ($in_s | not) and $in_c then
                # Rule 2: the source does not define this path but the deployed
                # config has it. Which of the two reasons applies is decided by
                # ORIG, and only orig can decide it (#581):
                #
                #   in orig  → the release DID define it and now does not, i.e.
                #              the module author removed the field. Keeping it
                #              made the key unremovable: `modify` merged source
                #              over deployed forever, so a stale value outlived
                #              the field that gave it meaning, and reconcile
                #              could not see the difference. Drop it.
                #   not in orig → it was never in the release, so the operator
                #              added it by hand — the case this rule exists for.
                #              Keep, exactly as before.
                #
                # A missing .orig is backfilled from source upstream, so an
                # absent path there also means "no evidence the release ever had
                # it" and lands on the safe side: keep.
                if $in_o then
                    .removed += [{ field: ($p | join(".")),
                                   was: $cv,
                                   customized: ($cv != $ov) }]
                else
                    .result = (.result | setpath($p; $cv))
                    | .kept += [$p | join(".")]
                end
              elif ($in_c | not) and $in_s then
                # Rule 3: new release field → adopt
                .result = (.result | setpath($p; $sv))
                | .added += [$p | join(".")]
              elif $in_o and ($cv == $ov) then
                # Rule 4: operator untouched → follow release
                if $sv == $cv then
                    # No actual change — adopt silently.
                    .result = (.result | setpath($p; $sv))
                else
                    # #511: the module author changed a field the operator never
                    # touched — capture before/after so it is reported, not silent.
                    .result = (.result | setpath($p; $sv))
                    | .adopted += [{ field: ($p | join(".")), before: $cv, after: $sv }]
                end
              else
                # Rule 5: operator-pinned (current diverged from orig, or no
                # orig snapshot for this path — treat as pinned).
                if $in_c then
                    .result = (.result | setpath($p; $cv))
                    | (if $in_s and ($sv != $cv) then .pinned += [$p | join(".")] else . end)
                else . end
              end
        )
    ')"

    # Pull merged config + report fields.
    local merged_flat
    merged_flat="$(jq -c '.result' <<<"${merged_with_report}")"

    if ! jq empty <<<"${merged_flat}" 2>/dev/null; then
        error "  Merge produced invalid JSON — leaving ${current} unchanged"
        return 1
    fi

    # Log a summary of what changed.
    local n_adopted n_pinned n_added n_kept n_removed
    n_adopted=$(jq '.adopted | length' <<<"${merged_with_report}")
    n_pinned=$(jq  '.pinned  | length' <<<"${merged_with_report}")
    n_added=$(jq   '.added   | length' <<<"${merged_with_report}")
    n_kept=$(jq    '.kept    | length' <<<"${merged_with_report}")
    n_removed=$(jq '.removed | length' <<<"${merged_with_report}")

    debug "  Merge: ${n_adopted} adopted, ${n_pinned} pinned, ${n_added} added, ${n_kept} kept (orphan), ${n_removed} removed"

    # #581: a field the release dropped is DELETED from the deployed config, so
    # say so with the value that went — never silently. A field the operator had
    # also customized is a warn, not an info: their edit is being discarded
    # because the field it applied to no longer exists, and `modify --set` is how
    # they get it back if the removal was not what they wanted.
    if [[ "${n_removed}" -gt 0 ]]; then
        local _removed_line
        while IFS= read -r _removed_line; do
            case "${_removed_line}" in
                CUSTOMIZED*) warn "  ${_removed_line#CUSTOMIZED }" ;;
                *)           info "    ${_removed_line}" ;;
            esac
        done < <(jq -r '
            .removed[]
            | if .customized
              then "CUSTOMIZED removed \(.field) (no longer in the release) — your customized value \(.was|tojson) was discarded"
              else "removed (no longer in the release): \(.field) = \(.was|tojson)"
              end
        ' <<<"${merged_with_report}")
    fi
    if [[ "${n_adopted}" -gt 0 ]]; then
        # #511: adopting a CHANGED released value is NOT silent — the module
        # author changed a field the operator never customized, and the operator
        # must see it with before/after. (Unchanged adoptions never reach
        # .adopted, so this only fires on real release-value changes.)
        local _adopted_line
        while IFS= read -r _adopted_line; do
            warn "  ${_adopted_line}"
        done < <(jq -r '
            .adopted[]
            | "Changed the released value of \(.field): \(.before|tojson) -> \(.after|tojson)"
        ' <<<"${merged_with_report}")
    fi
    if [[ "${n_pinned}" -gt 0 ]]; then
        local pinned_list
        pinned_list=$(jq -r '.pinned | join(", ")' <<<"${merged_with_report}")
        info "    pinned (operator customizations preserved): ${pinned_list}"
    fi
    if [[ "${n_added}" -gt 0 ]]; then
        local added_list
        added_list=$(jq -r '.added | join(", ")' <<<"${merged_with_report}")
        info "    added (new in release): ${added_list}"
    fi

    # Render the canonical Pattern A form for on-disk storage.
    local merged_canonical
    merged_canonical="$(printf '%s\n' "${merged_flat}" | regroup_to_pattern_a)"

    if ! jq empty <<<"${merged_canonical}" 2>/dev/null; then
        error "  Canonical render produced invalid JSON — leaving ${current} unchanged"
        return 1
    fi

    # Atomic replace.
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "${merged_canonical}" > "${tmp}"
    mv "${tmp}" "${current}"

    # Advance the baseline.
    cp "${source}" "${orig}"

    if [[ "${backfilled}" -eq 1 ]]; then
        debug "  ${eff}: 3-way merge complete (backfilled .orig from source)"
    else
        debug "  ${eff}: 3-way merge complete"
    fi
    return 0
}

# CLI wrapper.
_merge_cli() {
    local SCRIPT_NAME
    SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")"

    local eff=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<EOF
Usage: ${SCRIPT_NAME} <effective-module>

Run a 3-way merge for the named installed module. Resolves the module's source
directory via its .location field, then reconciles against the new release.

The merge:
  - adopts release changes for fields the operator hasn't touched,
  - preserves operator customizations for fields where current != .orig,
  - writes the merged config in canonical Pattern A form,
  - advances .orig to match the new release.

If .orig does not exist (pre-#207 install), it is backfilled from the source
so existing customizations remain pinned.
EOF
                return 0
                ;;
            *)
                if [[ -z "${eff}" ]]; then eff="$1"
                else error "Unexpected argument: $1"; return 2; fi
                shift
                ;;
        esac
    done

    if [[ -z "${eff}" ]]; then
        error "An effective module name is required"
        return 2
    fi

    local current="${_MERGE_CONFIG_DIR}/${eff}.json"
    if [[ ! -f "${current}" ]]; then
        error "Module not installed: ${current}"
        return 1
    fi

    # Resolve module_dir from the installed .location field.
    local module_dir
    module_dir="$(jq -r '.location // ""' "${current}")"
    if [[ -z "${module_dir}" || ! -d "${module_dir}" ]]; then
        # Fall back to get_module_dir if common-install-routines is sourced.
        if declare -F get_module_dir >/dev/null 2>&1; then
            module_dir="$(get_module_dir "${eff}" 2>/dev/null)"
        fi
    fi
    if [[ -z "${module_dir}" || ! -d "${module_dir}" ]]; then
        error "Cannot resolve module directory for '${eff}' (no .location field)"
        return 1
    fi

    apply_three_way_merge "${eff}" "${module_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _merge_cli "$@"
fi
