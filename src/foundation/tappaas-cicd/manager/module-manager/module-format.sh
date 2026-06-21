#!/usr/bin/env bash
#
# TAPPaaS module-format — convert a module JSON between the flat form and the
# Pattern-A `config`-block form (issue #161, Pattern C hybrid).
#
# Both forms are equivalent: TAPPaaS normalizes Pattern A to flat at deploy and
# at validation, so this tool is purely an authoring convenience.
#
# Usage:
#   module-format.sh to-flat   <file.json> [--in-place]
#   module-format.sh to-config <file.json> [--in-place]
#
#   to-flat     Flatten any `config` block up to top-level flat fields.
#   to-config   Group service-owned flat fields under config["<module>:<service>"]
#               coordinates, inferred from each field's `usedBy` in
#               module-fields.json intersected with the module's dependsOn.
#               Module-identity fields (vmname, vmid, vmtag, node, zone0/1) and
#               general fields stay in the header. The result is a starting
#               point — review and adjust ownership by hand.
#
# Without --in-place the converted JSON is written to stdout (the input file is
# left untouched).
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly SCHEMA_FILE="/home/tappaas/TAPPaaS/src/foundation/module-fields.json"

# Header-pinned fields: module identity / placement that is owned by the module
# itself (read by several services), never nested under a single service.
readonly HEADER_PINNED='["vmname","vmid","vmtag","node","zone0","zone1","mac0","mac1","dependsOn","provides","config"]'

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || {
    info()  { echo "[Info] $*"; }
    warn()  { echo "[Warning] $*" >&2; }
    error() { echo "[Error] $*" >&2; }
    die()   { error "$@"; exit 1; }
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <to-flat|to-config> <file.json> [--in-place]

Convert a TAPPaaS module JSON between the flat form and the Pattern-A
\`config\`-block form (issue #161). Both are equivalent; normalization to flat
happens automatically at deploy/validation.

Commands:
    to-flat     Flatten any config block into flat top-level fields.
    to-config   Group service-owned fields under config["<module>:<service>"].

Options:
    --in-place  Rewrite the file instead of printing to stdout.
    -h, --help  Show this help.
EOF
}

# ── Arguments ────────────────────────────────────────────────────────

CMD="" FILE="" IN_PLACE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --in-place) IN_PLACE=true ;;
        to-flat|to-config) CMD="$1" ;;
        -*) die "Unknown option: $1" ;;
        *) [[ -z "${FILE}" ]] && FILE="$1" || die "Unexpected argument: $1" ;;
    esac
    shift
done

[[ -z "${CMD}" ]] && { error "A command is required"; usage; exit 1; }
[[ -z "${FILE}" ]] && { error "A module JSON file is required"; usage; exit 1; }
[[ -f "${FILE}" ]] || die "File not found: ${FILE}"
jq empty "${FILE}" 2>/dev/null || die "Invalid JSON: ${FILE}"

# ── Conversions ──────────────────────────────────────────────────────

to_flat() {
    # Flatten config blocks into top-level fields (the normalized form).
    jq '
        if (.config | type) == "object"
        then reduce (.config | to_entries[]) as $s (.; . * $s.value) | del(.config)
        else . end
    ' "${FILE}"
}

to_config() {
    [[ -f "${SCHEMA_FILE}" ]] || die "Schema not found: ${SCHEMA_FILE}"
    # For each flat field, find the single declared dependency that owns it
    # (its usedBy ∩ dependsOn has exactly one element) and move it under
    # config[<coordinate>]. Header-pinned and general fields, and fields whose
    # ownership is ambiguous (0 or >1 matches), stay in the header.
    jq --slurpfile schema "${SCHEMA_FILE}" --argjson pinned "${HEADER_PINNED}" '
        ($schema[0].fields) as $fields
        | (.dependsOn // []) as $deps
        | . as $doc
        # owner(field): the single dependsOn coordinate in the field usedBy, else null
        | def owner($f):
            ($fields[$f].usedBy // []) as $u
            | [ $u[] | select(. as $s | $deps | index($s)) ] as $m
            | if ($m | length) == 1 then $m[0] else null end;
        # Partition the existing flat fields.
        ([ keys[] | select(. as $k | ($pinned | index($k)) | not) | select(owner(.) != null) ]) as $movable
        | reduce $movable[] as $k (
            . ;
            (owner($k)) as $svc
            | .config[$svc] = ((.config[$svc] // {}) + { ($k): $doc[$k] })
            | del(.[$k])
          )
    ' "${FILE}"
}

case "${CMD}" in
    to-flat)   result=$(to_flat) ;;
    to-config) result=$(to_config) ;;
esac

if [[ "${IN_PLACE}" == true ]]; then
    tmp=$(mktemp)
    printf '%s\n' "${result}" > "${tmp}"
    jq empty "${tmp}" || { rm -f "${tmp}"; die "Conversion produced invalid JSON — file left unchanged"; }
    mv "${tmp}" "${FILE}"
    info "Rewrote ${FILE} (${CMD})"
else
    printf '%s\n' "${result}"
fi
