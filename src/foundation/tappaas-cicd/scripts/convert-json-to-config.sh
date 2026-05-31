#!/usr/bin/env bash
#
# convert-json-to-config.sh — flat → Pattern A converter (#207).
#
# Groups every service-owned flat field of a module JSON under
# `config.<module>:<service>`, leaving header fields (vmname, vmid, vmtag,
# node, zone*, mac*, dependsOn, provides, config) and `general` fields at the
# top level. Used both as:
#
#   * a one-shot migration tool for converting the repo's source jsons to the
#     canonical Pattern A form, and
#   * a sourceable library (function `regroup_to_pattern_a`) called by
#     apply-json-merge.sh and copy-update-json.sh to render any flat JSON in
#     the canonical on-disk form.
#
# Field-to-coordinate mapping (per #207 decision):
#   1. Header-pinned (HEADER_PINNED below): stay at top.
#   2. usedBy == ["general"]:                  stay at top.
#   3. Field not present in schema:            stay at top + warn (unknown).
#   4. usedBy ∩ dependsOn == ∅:                stay at top + warn (orphan).
#   5. usedBy ∩ dependsOn has ≥1 match:        config.<first-match-in-dependsOn-order>
#
# After grouping, top-level keys are reordered per .fieldOrder in
# module-fields.json; within each config block, keys are also reordered.
#
# Usage (CLI):
#   convert-json-to-config.sh <module-json>            # stdout
#   convert-json-to-config.sh --in-place <module-json>
#   convert-json-to-config.sh --dry-run <module-json>  # show diff
#
# Usage (sourceable):
#   . /home/tappaas/bin/convert-json-to-config.sh
#   regroup_to_pattern_a < flat.json > patternA.json
#
# Exit codes:
#   0  success
#   1  invalid JSON / unreadable file
#   2  bad arguments
#

# Note: when sourced, callers may want strict mode of their own; do NOT enable
# `set -euo pipefail` at sourcing time. Only enable it when run as CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Guard against double-sourcing: readonly fails the second time.
if [[ -z "${_CONVERT_SCHEMA_FILE:-}" ]]; then
    readonly _CONVERT_SCHEMA_FILE="${TAPPAAS_SCHEMA_FILE:-/home/tappaas/TAPPaaS/src/foundation/module-fields.json}"
    readonly _CONVERT_HEADER_PINNED='["vmname","vmid","vmtag","node","zone0","zone1","mac0","mac1","dependsOn","provides","config","variant"]'
fi

# ── Helpers when sourced into a script without common-install-routines ────
_convert_have_log_funcs() {
    declare -F info >/dev/null 2>&1 && declare -F warn >/dev/null 2>&1 \
        && declare -F error >/dev/null 2>&1 && declare -F die >/dev/null 2>&1
}
if ! _convert_have_log_funcs; then
    info()  { echo "[Info] $*"; }
    warn()  { echo "[Warning] $*" >&2; }
    error() { echo "[Error] $*" >&2; }
    die()   { error "$@"; exit 1; }
fi

# Public function: take flat JSON on stdin, emit Pattern A JSON on stdout.
# All warnings go to stderr. Pre-existing config blocks are merged in (i.e.,
# input that's already Pattern A is normalized first, then regrouped — so
# this function is idempotent).
regroup_to_pattern_a() {
    [[ -f "${_CONVERT_SCHEMA_FILE}" ]] || die "Schema not found: ${_CONVERT_SCHEMA_FILE}"

    local input
    input="$(cat)"
    jq empty <<<"${input}" 2>/dev/null || die "Input is not valid JSON"

    # 1. Flatten any pre-existing config block first (idempotency).
    input="$(jq '
        if (.config | type) == "object"
        then reduce (.config | to_entries[]) as $s (.; . * $s.value) | del(.config)
        else . end
    ' <<<"${input}")"

    # 2. Emit warnings about unknown / orphan fields before grouping. These do
    #    not block the conversion; they just stay at the top level.
    local warnings
    warnings="$(jq -r --slurpfile schema "${_CONVERT_SCHEMA_FILE}" --argjson pinned "${_CONVERT_HEADER_PINNED}" '
        ($schema[0].fields) as $fields
        | (.dependsOn // []) as $deps
        | [ keys[]
            | select(. as $k | ($pinned | index($k)) | not)
            | . as $k
            | ($fields[$k].usedBy // []) as $u
            | if $fields[$k] == null then
                {kind: "unknown", field: $k}
              elif ($u | index("general")) != null then
                empty
              else
                [ $u[] | select(. as $s | $deps | index($s)) ] as $m
                | if ($m | length) == 0 then
                    {kind: "orphan", field: $k, usedBy: $u}
                  else empty end
              end
          ]
        | .[] | "\(.kind)\t\(.field)\t\((.usedBy // []) | join(","))"
    ' <<<"${input}")"

    if [[ -n "${warnings}" ]]; then
        while IFS=$'\t' read -r kind field used_by; do
            [[ -z "${kind}" ]] && continue
            case "${kind}" in
                unknown)
                    warn "  field '${field}' is not in the schema — kept at top level" >&2
                    ;;
                orphan)
                    warn "  field '${field}' is usedBy=[${used_by}] but the module does not depend on any of them — kept at top level" >&2
                    ;;
            esac
        done <<<"${warnings}"
    fi

    # 3. Regroup. For each flat field whose owner is determinable (rule 5),
    #    move it under config[<owner>]. Owner is the FIRST dep in dependsOn
    #    order that also appears in the field's usedBy.
    #
    # 4. Sort top-level keys by fieldOrder (unknown keys after, in input order).
    # 5. Within each config block, sort by fieldOrder.
    jq --slurpfile schema "${_CONVERT_SCHEMA_FILE}" --argjson pinned "${_CONVERT_HEADER_PINNED}" '
        # owner(field): first match in dependsOn order whose key is also in field.usedBy
        def owner($f; $fields; $deps):
            ($fields[$f].usedBy // []) as $u
            | if ($u | index("general")) != null then null
              else
                [ $deps[] | select(. as $d | $u | index($d)) ] as $m
                | if ($m | length) >= 1 then $m[0] else null end
              end;

        # Reorder object keys by fieldOrder; unknown keys preserve insertion order.
        def reorder($obj; $order):
            ($obj | keys_unsorted) as $ks
            | ([ $order[] | select(. as $k | $obj | has($k)) ]) as $known
            | ([ $ks[]   | select(. as $k | $order | index($k) | not) ]) as $rest
            | ($known + $rest) as $final
            | reduce $final[] as $k ({}; .[$k] = $obj[$k]);

        ($schema[0].fields) as $fields
        | ($schema[0].fieldOrder // []) as $order
        | (.dependsOn // []) as $deps
        | . as $doc

        # Partition into movable (have determinable owner) vs stay-at-top.
        | ([ keys[]
              | select(. as $k | ($pinned | index($k)) | not)
              | select(owner(.; $fields; $deps) != null) ]) as $movable

        | reduce $movable[] as $k (
            . ;
            (owner($k; $fields; $deps)) as $svc
            | .config[$svc] = ((.config[$svc] // {}) + { ($k): $doc[$k] })
            | del(.[$k])
          )

        # Reorder top-level + each config sub-block.
        | reorder(.; $order) as $top
        | $top
        | if (.config | type) == "object" then
            .config = (
                .config | to_entries
                | map(.value = reorder(.value; $order))
                | from_entries
            )
          else . end
    ' <<<"${input}"
}

# ── CLI ─────────────────────────────────────────────────────────────────
_convert_cli() {
    local SCRIPT_NAME
    SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")"

    local file="" in_place=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<EOF
Usage: ${SCRIPT_NAME} [--in-place|--dry-run] <module-json>

Convert a flat module JSON to canonical Pattern A (config-block) form.

Options:
    --in-place   Overwrite the input file with the converted JSON.
    --dry-run    Print a diff against the input; do not write.
    -h, --help   Show this help.

Output without flags goes to stdout (input is left untouched).
EOF
                return 0
                ;;
            --in-place) in_place=1; shift ;;
            --dry-run)  dry_run=1;  shift ;;
            -*)         error "Unknown option: $1"; return 2 ;;
            *)
                if [[ -z "${file}" ]]; then
                    file="$1"
                else
                    error "Unexpected argument: $1"; return 2
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${file}" ]]; then
        error "A module JSON file is required"; return 2
    fi
    if [[ ! -f "${file}" ]]; then
        error "File not found: ${file}"; return 1
    fi
    if ! jq empty "${file}" 2>/dev/null; then
        error "Invalid JSON: ${file}"; return 1
    fi

    local converted
    converted="$(regroup_to_pattern_a < "${file}")"
    # Re-validate the output.
    jq empty <<<"${converted}" 2>/dev/null || { error "Conversion produced invalid JSON — original left unchanged"; return 1; }

    if [[ "${dry_run}" -eq 1 ]]; then
        diff -u "${file}" <(printf '%s\n' "${converted}") || true
        return 0
    fi

    if [[ "${in_place}" -eq 1 ]]; then
        local tmp
        tmp="$(mktemp)"
        printf '%s\n' "${converted}" > "${tmp}"
        mv "${tmp}" "${file}"
        info "Rewrote ${file}"
    else
        printf '%s\n' "${converted}"
    fi
}

# Run CLI only when invoked as a script, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _convert_cli "$@"
fi
