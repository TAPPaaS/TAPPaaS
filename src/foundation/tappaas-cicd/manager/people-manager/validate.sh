#!/usr/bin/env bash
#
# validate-people.sh — validate a People domain (roles/organizations/groups/users)
#
# Validates every JSON file under a config/people-style directory against the
# People JSON Schemas (src/foundation/schemas/{role,organization,group,user}-fields.json)
# and checks cross-file reference integrity:
#   - group.ownerOrg references an existing Organization
#   - user.memberOf references existing Groups
#   - user.roles and group.roles reference existing Roles
#   - organization.owner references an existing User
#   - organization.parentOrg (if set) references an existing Organization
#
# Schema conformance is checked with the project's available Python jsonschema
# (draft 2020-12). Reference integrity and the required-field/enum re-check are
# performed with jq — the same mechanism used by validate-configuration.sh.
#
# Usage: validate-people.sh [OPTIONS] [DIR]
#
# Exit codes: 0 = all checks pass (warnings allowed), 1 = validation errors found
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse the project's common-install-routines.sh when present
# ---------------------------------------------------------------------------
if ! declare -F info &>/dev/null; then
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
# Locate schemas relative to this script (manager/people-manager/ -> foundation/schemas)
# ---------------------------------------------------------------------------
# Resolve the REAL script path: validate.sh is symlinked into /home/tappaas/bin
# (as validate-people.sh), so BASH_SOURCE alone would point at the symlink dir
# and the default schema dir wouldn't be found. readlink -f follows the link.
_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${_SELF}")" && pwd)"
# manager/people-manager -> manager -> tappaas-cicd -> foundation
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${SCHEMA_DIR:-${FOUNDATION_DIR}/schemas}"

# Defaults
PEOPLE_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}/people"
QUIET=false
ERRORS=0
WARNINGS=0

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [DIR]

Validate a TAPPaaS People domain against the People schemas and check
cross-file reference integrity.

Arguments:
    DIR                      People directory to validate (must contain
                             roles/ organizations/ groups/ users/).
                             Default: ${PEOPLE_DIR}

Options:
    -h, --help               Show this help message and exit
    --schema-dir <path>      Directory holding the *-fields.json schemas
                             (default: ${SCHEMA_DIR})
    --quiet                  Only output errors/warnings, suppress info

Exit Codes:
    0    All checks passed (warnings allowed)
    1    One or more validation errors found

Examples:
    $(basename "$0")
    $(basename "$0") /home/tappaas/TAPPaaS/config/people
    $(basename "$0") --quiet ./manager/people-manager/minimal-org
EOF
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
            *)  PEOPLE_DIR="$1"; shift ;;
        esac
    done
}

log_info() { [[ "$QUIET" == "false" ]] && info "$@" || true; }
validation_error() { error "VALIDATION: $*"; ERRORS=$((ERRORS + 1)); }
validation_warn()  { warn  "VALIDATION: $*"; WARNINGS=$((WARNINGS + 1)); }

# ---------------------------------------------------------------------------
# Schema conformance — Python jsonschema (draft 2020-12) if available.
# Returns 0 and prints nothing on success; prints a message and returns 1 on
# failure. Falls back to a jq-only required-field/enum check if jsonschema
# is unavailable.
# ---------------------------------------------------------------------------
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

    # jq fallback: required fields present + type is object
    jq -e 'type == "object"' "$instance" >/dev/null 2>&1 || {
        validation_error "$(basename "$instance"): top-level value is not a JSON object"
        return 1
    }
    local req
    req="$(jq -r '.required[]?' "$schema" 2>/dev/null)"
    local missing=0 field
    while IFS= read -r field; do
        [[ -z "$field" ]] && continue
        if [[ "$(jq -r --arg f "$field" 'has($f)' "$instance")" != "true" ]]; then
            validation_error "$(basename "$instance"): missing required field '${field}'"
            missing=1
        fi
    done <<< "$req"
    [[ "$missing" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Collect names of a category into a newline-delimited list (via .name field).
# ---------------------------------------------------------------------------
collect_names() {
    # $1 = subdir
    local dir="${PEOPLE_DIR}/$1" f
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.json; do
        [[ -e "$f" ]] || continue
        jq -r '.name // empty' "$f" 2>/dev/null || true
    done
}

contains_line() {
    # $1 = needle, $2 = haystack (newline-delimited). Returns 0 if present.
    local needle="$1" haystack="$2"
    printf '%s\n' "$haystack" | grep -qxF -- "$needle"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    PEOPLE_DIR="${PEOPLE_DIR%/}"

    log_info "Validating People domain: ${PEOPLE_DIR}"
    log_info "Using schemas from: ${SCHEMA_DIR}"

    # Schema files must exist
    local s
    for s in role organization group user; do
        [[ -f "${SCHEMA_DIR}/${s}-fields.json" ]] || \
            die "Schema not found: ${SCHEMA_DIR}/${s}-fields.json"
    done

    [[ -d "$PEOPLE_DIR" ]] || die "People directory not found: ${PEOPLE_DIR}"

    detect_jsonschema || validation_warn "python3 jsonschema not available — falling back to jq required-field checks only"

    # --- JSON well-formedness + schema conformance ---
    local category subdir schema f
    for category in role:roles organization:organizations group:groups user:users; do
        subdir="${category#*:}"
        schema="${SCHEMA_DIR}/${category%%:*}-fields.json"
        local dir="${PEOPLE_DIR}/${subdir}"
        if [[ ! -d "$dir" ]]; then
            validation_warn "missing subdirectory: ${subdir}/"
            continue
        fi
        for f in "$dir"/*.json; do
            [[ -e "$f" ]] || continue
            if ! jq empty "$f" >/dev/null 2>&1; then
                validation_error "$(basename "$f"): not valid JSON"
                continue
            fi
            validate_against_schema "$f" "$schema" || true
        done
    done

    # --- Reference integrity ---
    local roles orgs groups users
    roles="$(collect_names roles)"
    orgs="$(collect_names organizations)"
    groups="$(collect_names groups)"
    users="$(collect_names users)"

    # organization.owner -> user ; organization.parentOrg -> org
    if [[ -d "${PEOPLE_DIR}/organizations" ]]; then
        for f in "${PEOPLE_DIR}/organizations"/*.json; do
            [[ -e "$f" ]] || continue
            jq empty "$f" >/dev/null 2>&1 || continue
            local oname owner parent
            oname="$(jq -r '.name // empty' "$f")"
            owner="$(jq -r '.owner // empty' "$f")"
            parent="$(jq -r '.parentOrg // empty' "$f")"
            if [[ -n "$owner" ]] && ! contains_line "$owner" "$users"; then
                validation_error "organization '${oname}': owner references unknown user '${owner}'"
            fi
            if [[ -n "$parent" ]] && ! contains_line "$parent" "$orgs"; then
                validation_error "organization '${oname}': parentOrg references unknown organization '${parent}'"
            fi
        done
    fi

    # group.ownerOrg -> org ; group.roles[] -> role
    if [[ -d "${PEOPLE_DIR}/groups" ]]; then
        for f in "${PEOPLE_DIR}/groups"/*.json; do
            [[ -e "$f" ]] || continue
            jq empty "$f" >/dev/null 2>&1 || continue
            local gname ownerorg role
            gname="$(jq -r '.name // empty' "$f")"
            ownerorg="$(jq -r '.ownerOrg // empty' "$f")"
            if [[ -n "$ownerorg" ]] && ! contains_line "$ownerorg" "$orgs"; then
                validation_error "group '${gname}': ownerOrg references unknown organization '${ownerorg}'"
            fi
            while IFS= read -r role; do
                [[ -z "$role" ]] && continue
                if ! contains_line "$role" "$roles"; then
                    validation_error "group '${gname}': roles[] references unknown role '${role}'"
                fi
            done < <(jq -r '.roles[]? // empty' "$f")
        done
    fi

    # user.memberOf[] -> group ; user.roles[] -> role
    if [[ -d "${PEOPLE_DIR}/users" ]]; then
        for f in "${PEOPLE_DIR}/users"/*.json; do
            [[ -e "$f" ]] || continue
            jq empty "$f" >/dev/null 2>&1 || continue
            local uname grp role
            uname="$(jq -r '.name // empty' "$f")"
            while IFS= read -r grp; do
                [[ -z "$grp" ]] && continue
                if ! contains_line "$grp" "$groups"; then
                    validation_error "user '${uname}': memberOf references unknown group '${grp}'"
                fi
            done < <(jq -r '.memberOf[]? // empty' "$f")
            while IFS= read -r role; do
                [[ -z "$role" ]] && continue
                if ! contains_line "$role" "$roles"; then
                    validation_error "user '${uname}': roles[] references unknown role '${role}'"
                fi
            done < <(jq -r '.roles[]? // empty' "$f")
        done
    fi

    # --- Summary ---
    echo ""
    if [[ $ERRORS -gt 0 ]]; then
        error "People validation failed: $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warn "People validation passed with $WARNINGS warning(s)"
        exit 0
    else
        log_info "${GN:-}People validation passed: all checks OK${CL:-}"
        exit 0
    fi
}

main "$@"
