#!/usr/bin/env bash
#
# validate-environment.sh — validate environment JSON files (ADR-007 P3)
#
# Validates environment files against src/foundation/schemas/environment-fields.json
# (JSON Schema draft 2020-12) and checks reference integrity:
#   - network.zone references an existing zone in zones.json
#   - ownerOrg (when present) references an existing Organization
#     (config/people/organizations/<ownerOrg>.json)
#   - an authored tlsCertRefid anywhere in the file is REJECTED
#     (it is runtime state, not authored config — ADR-007 "TLS certificate handling")
#
# Schema conformance uses the project's Python jsonschema when available, with a
# jq-only required-field fallback otherwise — the same mechanism as validate-site.sh
# and people-manager's validate.sh.
#
# Usage: validate-environment.sh [OPTIONS] [FILE|DIR]
#
# Arguments:
#   FILE|DIR             environment .json file, OR a directory of them
#                        (default: ${TAPPAAS_CONFIG:-/home/tappaas/config}/environments)
#
# Options:
#   --schema-dir PATH    directory holding environment-fields.json (default: derived)
#   --config-dir DIR     config dir for zones.json + organizations lookup
#                        (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --zones FILE         path to zones.json (default: <config-dir>/zones.json)
#   --quiet              only output errors/warnings
#   -h, --help           show this help and exit
#
# Exit codes: 0 = valid (warnings allowed); 1 = validation errors found.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse common-install-routines.sh when present
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        # shellcheck source=/dev/null
        . /home/tappaas/bin/common-install-routines.sh
    else
        : "${GN:=$'\033[1;92m'}"
        : "${RD:=$'\033[01;31m'}"
        : "${YW:=$'\033[33m'}"
        : "${DGN:=$'\033[32m'}"
        : "${CL:=$'\033[m'}"
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        debug() { :; }
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$*"; exit 1; }
    fi
fi

command -v jq >/dev/null 2>&1 || die "jq is required but not installed."

# ---------------------------------------------------------------------------
# Resolve the REAL script path: validate-environment.sh is symlinked into
# /home/tappaas/bin, so BASH_SOURCE alone points at the symlink dir and the
# default schema dir wouldn't be found. readlink -f follows the link.
# ---------------------------------------------------------------------------
_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${_SELF}")" && pwd)"
# manager/environment-manager -> manager -> tappaas-cicd -> foundation
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${SCHEMA_DIR:-${FOUNDATION_DIR}/schemas}"

CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
TARGET=""
ZONES_FILE=""
QUIET=false
ERRORS=0
WARNINGS=0

usage() {
    sed -n '2,33p' "$_SELF" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --schema-dir)
                [[ -n "${2:-}" ]] || die "--schema-dir requires a path argument"
                SCHEMA_DIR="$2"; shift 2 ;;
            --config-dir)
                [[ -n "${2:-}" ]] || die "--config-dir requires a path argument"
                CONFIG_DIR="$2"; shift 2 ;;
            --zones)
                [[ -n "${2:-}" ]] || die "--zones requires a path argument"
                ZONES_FILE="$2"; shift 2 ;;
            --quiet) QUIET=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  TARGET="$1"; shift ;;
        esac
    done
}

log_info() { [[ "$QUIET" == "false" ]] && info "$@" || true; }
validation_error() { error "VALIDATION: $*"; ERRORS=$((ERRORS + 1)); }
validation_warn()  { warn  "VALIDATION: $*"; WARNINGS=$((WARNINGS + 1)); }

HAVE_JSONSCHEMA=""
detect_jsonschema() {
    if [[ -z "$HAVE_JSONSCHEMA" ]]; then
        if command -v python3 >/dev/null 2>&1 && \
           python3 -c "import jsonschema" >/dev/null 2>&1; then
            HAVE_JSONSCHEMA="yes"
        else
            HAVE_JSONSCHEMA="no"
        fi
    fi
    [[ "$HAVE_JSONSCHEMA" == "yes" ]]
}

validate_against_schema() {
    # $1 = instance file, $2 = schema file
    local instance="$1" schema="$2" out
    if detect_jsonschema; then
        if out="$(python3 - "$schema" "$instance" << 'PY' 2>&1
import json, sys
import jsonschema
schema_path, instance_path = sys.argv[1], sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(instance_path) as f:
    instance = json.load(f)
validator = jsonschema.Draft202012Validator(schema)
errs = sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
if errs:
    for e in errs:
        loc = "/".join(str(p) for p in e.path) or "(root)"
        print(f"{loc}: {e.message}")
    sys.exit(1)
PY
        )"; then
            return 0
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && validation_error "$(basename "$instance"): $line"
            done <<< "$out"
            return 1
        fi
    fi

    # jq fallback: top-level object + required fields present
    jq -e 'type == "object"' "$instance" >/dev/null 2>&1 || {
        validation_error "$(basename "$instance"): top-level value is not a JSON object"
        return 1
    }
    local req field missing=0
    req="$(jq -r '.required[]?' "$schema" 2>/dev/null)"
    while IFS= read -r field; do
        [[ -z "$field" ]] && continue
        if [[ "$(jq -r --arg f "$field" 'has($f)' "$instance")" != "true" ]]; then
            validation_error "$(basename "$instance"): missing required field '${field}'"
            missing=1
        fi
    done <<< "$req"
    [[ "$missing" -eq 0 ]]
}

# Reference + cross-field integrity for a single environment file.
validate_references() {
    # $1 = instance file
    local instance="$1" base
    base="$(basename "$instance")"

    # Reject an authored tlsCertRefid ANYWHERE (belt-and-braces over the schema,
    # which already rejects it via additionalProperties:false).
    if jq -e '.. | objects | has("tlsCertRefid")' "$instance" >/dev/null 2>&1; then
        validation_error "${base}: authored 'tlsCertRefid' is not allowed (it is runtime state, not config)"
    fi

    # network.zone must exist in zones.json (when zones.json is available).
    local zone
    zone="$(jq -r '.network.zone // empty' "$instance")"
    if [[ -n "$zone" ]]; then
        if [[ -f "$ZONES_FILE" ]]; then
            if [[ "$(jq -r --arg z "$zone" 'has($z)' "$ZONES_FILE" 2>/dev/null)" != "true" ]]; then
                validation_error "${base}: network.zone references unknown zone '${zone}' (not in ${ZONES_FILE})"
            fi
        else
            validation_warn "${base}: zones.json not found at ${ZONES_FILE} — skipping zone reference check"
        fi
    fi

    # ownerOrg (when non-empty) must reference an existing organization.
    local owner orgfile
    owner="$(jq -r '.ownerOrg // empty' "$instance")"
    if [[ -n "$owner" ]]; then
        orgfile="${CONFIG_DIR}/people/organizations/${owner}.json"
        if [[ ! -f "$orgfile" ]]; then
            validation_error "${base}: ownerOrg references unknown organization '${owner}' (no ${orgfile})"
        fi
    fi
}

main() {
    parse_args "$@"

    CONFIG_DIR="${CONFIG_DIR%/}"
    [[ -n "$TARGET" ]]     || TARGET="${CONFIG_DIR}/environments"
    [[ -n "$ZONES_FILE" ]] || ZONES_FILE="${CONFIG_DIR}/zones.json"

    local schema="${SCHEMA_DIR}/environment-fields.json"
    [[ -f "$schema" ]] || die "Schema not found: ${schema}"

    # Collect target files.
    local files=()
    if [[ -d "$TARGET" ]]; then
        local f
        for f in "$TARGET"/*.json; do
            [[ -e "$f" ]] || continue
            files+=("$f")
        done
        [[ ${#files[@]} -gt 0 ]] || validation_warn "no environment .json files found in ${TARGET}"
    elif [[ -f "$TARGET" ]]; then
        files+=("$TARGET")
    else
        die "Environment target not found: ${TARGET}"
    fi

    log_info "Validating environments: ${TARGET}"
    log_info "Using schema: ${schema}"
    detect_jsonschema || validation_warn "python3 jsonschema not available — falling back to jq required-field checks only"

    local instance
    for instance in "${files[@]}"; do
        if ! jq empty "$instance" >/dev/null 2>&1; then
            validation_error "$(basename "$instance"): not valid JSON"
            continue
        fi
        validate_against_schema "$instance" "$schema" || true
        validate_references "$instance"
    done

    echo ""
    if [[ $ERRORS -gt 0 ]]; then
        error "Environment validation failed: $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warn "Environment validation passed with $WARNINGS warning(s)"
        exit 0
    else
        log_info "${GN:-}Environment validation passed: all checks OK${CL:-}"
        exit 0
    fi
}

main "$@"
