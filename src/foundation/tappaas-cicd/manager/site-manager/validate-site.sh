#!/usr/bin/env bash
#
# validate-site.sh — validate site.json against the Site JSON Schema (ADR-007 P2)
#
# Validates a single site.json file against
# src/foundation/schemas/site-fields.json (JSON Schema draft 2020-12).
#
# Schema conformance is checked with the project's Python jsonschema when
# available, with a jq-only required-field/type fallback otherwise — the same
# mechanism used by validate-configuration.sh and the people-manager validate.sh.
#
# Usage: validate-site.sh [OPTIONS] [FILE]
#
# Arguments:
#   FILE                 site.json to validate
#                        (default: ${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json)
#
# Options:
#   --schema-dir PATH    directory holding site-fields.json (default: derived)
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
# Locate the schema relative to the REAL script path. validate-site.sh is
# symlinked into /home/tappaas/bin, so BASH_SOURCE alone points at the symlink
# dir and the schema would not be found. readlink -f follows the link (known
# footgun — see people-manager/validate.sh and user-setup.sh).
# ---------------------------------------------------------------------------
_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${_SELF}")" && pwd)"
# manager/site-manager -> manager -> tappaas-cicd -> foundation
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${SCHEMA_DIR:-${FOUNDATION_DIR}/schemas}"

SITE_FILE="${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json"
QUIET=false
ERRORS=0
WARNINGS=0

usage() {
    sed -n '2,25p' "$_SELF" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --schema-dir)
                [[ -n "${2:-}" ]] || die "--schema-dir requires a path argument"
                SCHEMA_DIR="$2"; shift 2 ;;
            --quiet) QUIET=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  SITE_FILE="$1"; shift ;;
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

main() {
    parse_args "$@"

    local schema="${SCHEMA_DIR}/site-fields.json"
    [[ -f "$schema" ]] || die "Schema not found: ${schema}"
    [[ -f "$SITE_FILE" ]] || die "site.json not found: ${SITE_FILE}"

    log_info "Validating site.json: ${SITE_FILE}"
    log_info "Using schema: ${schema}"

    if ! jq empty "$SITE_FILE" >/dev/null 2>&1; then
        validation_error "$(basename "$SITE_FILE"): not valid JSON"
    else
        detect_jsonschema || validation_warn "python3 jsonschema not available — falling back to jq required-field checks only"
        validate_against_schema "$SITE_FILE" "$schema" || true
    fi

    echo ""
    if [[ $ERRORS -gt 0 ]]; then
        error "Site validation failed: $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warn "Site validation passed with $WARNINGS warning(s)"
        exit 0
    else
        log_info "${GN:-}Site validation passed: all checks OK${CL:-}"
        exit 0
    fi
}

main "$@"
