#!/usr/bin/env bash
#
# Copy a module JSON file to config directory and update fields.
#
# Usage: copy-update-json.sh <module-name> [--<field> <value>]...
#
# Example:
#   copy-update-json.sh identity --node "tappaas2" --cores 4
#
# This script:
#   1. Copies <module>.json from current directory to /home/tappaas/config/
#   2. Automatically sets the 'location' field to the module directory
#   3. Validates field names against module-fields.json schema
#   4. Modifies the copied JSON based on --<field> <value> arguments
#   5. Creates a .orig backup if modifications are made
#   6. Validates the resulting JSON
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"
readonly SCHEMA_FILE="/home/tappaas/TAPPaaS/src/foundation/module-fields.json"

# Color definitions (matching common-install-routines.sh)
readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly DGN=$'\033[32m'
readonly CL=$'\033[m'

info() {
    echo -e "${DGN}$*${CL}"
}

warn() {
    echo -e "${YW}[WARN]${CL} $*"
}

error() {
    echo -e "${RD}[ERROR]${CL} $*" >&2
}

die() {
    error "$@"
    exit 1
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <module-name> [--<field> <value>]...

Copy a module JSON file to the config directory and optionally update fields.

Arguments:
    module-name     Name of the module (expects ./<module-name>.json to exist)

Options:
    --<field> <value>   Set JSON field to value (can be repeated)
    -h, --help          Show this help message

Examples:
    ${SCRIPT_NAME} identity
    ${SCRIPT_NAME} identity --node "tappaas2" --cores 4
    ${SCRIPT_NAME} nextcloud --memory 4096 --zone0 "trusted"

Notes:
    - Source file must exist as ./<module-name>.json in current directory
    - The 'location' field is automatically set to the current directory
    - Field names are validated against module-fields.json schema
    - Fields can be added even if not present in source JSON
    - If fields are modified, a .orig backup is created
    - Integer fields (per schema) are stored as JSON numbers
    - String fields are stored as JSON strings
EOF
}

# Check if jq is available
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        die "Required command 'jq' not found. Please install it."
    fi
}

# Validate that a field name exists in the schema
# Returns: 0 if valid, 1 if invalid
validate_field_name() {
    local field="$1"

    if [[ ! -f "${SCHEMA_FILE}" ]]; then
        warn "Schema file not found: ${SCHEMA_FILE} - skipping field validation"
        return 0
    fi

    if jq -e --arg f "${field}" '.fields | has($f)' "${SCHEMA_FILE}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get the expected type of a field from the schema
# Returns: "integer", "string", or empty if not found
get_field_type() {
    local field="$1"

    if [[ ! -f "${SCHEMA_FILE}" ]]; then
        echo ""
        return
    fi

    jq -r --arg f "${field}" '.fields[$f].type // empty' "${SCHEMA_FILE}" 2>/dev/null
}

# List all valid field names from the schema
list_valid_fields() {
    if [[ ! -f "${SCHEMA_FILE}" ]]; then
        return
    fi

    jq -r '.fields | keys[]' "${SCHEMA_FILE}" 2>/dev/null
}

# Determine if a value should be treated as a number based on schema type
should_be_number() {
    local field="$1"
    local value="$2"
    local field_type

    field_type=$(get_field_type "${field}")

    if [[ "${field_type}" == "integer" ]]; then
        return 0
    fi

    # Fallback: check if value looks like a number
    [[ "$value" =~ ^-?[0-9]+$ ]]
}

# Main function
main() {
    check_dependencies

    # Check for help flag first
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate module name argument
    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    local module="$1"
    shift

    local source_json="./${module}.json"
    local dest_json="${CONFIG_DIR}/${module}.json"
    local orig_json="${CONFIG_DIR}/${module}.json.orig"

    # Validate source file exists
    if [[ ! -f "${source_json}" ]]; then
        die "Source file not found: ${source_json}"
    fi

    # Validate source JSON is valid
    if ! jq empty "${source_json}" 2>/dev/null; then
        die "Invalid JSON in source file: ${source_json}"
    fi

    # Ensure config directory exists
    mkdir -p "${CONFIG_DIR}"

    # Copy the file
    info "Copying ${source_json} to ${dest_json}"
    cp "${source_json}" "${dest_json}"

    # Get the absolute path of the module directory (where the source JSON resides)
    local module_dir
    module_dir="$(cd "$(dirname "${source_json}")" && pwd)"

    # Automatically set the 'location' field
    local tmp_file
    tmp_file=$(mktemp)
    if ! jq --arg loc "${module_dir}" '.location = $loc' "${dest_json}" > "${tmp_file}"; then
        rm -f "${tmp_file}"
        die "Failed to set location field"
    fi
    mv "${tmp_file}" "${dest_json}"
    info "  Set location = ${module_dir}"

    # Parse and apply field modifications
    local has_modifications=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*)
                local field="${1#--}"
                if [[ -z "${2:-}" ]]; then
                    die "Option --${field} requires a value"
                fi
                local value="$2"
                shift 2

                # Validate field name against schema
                if ! validate_field_name "${field}"; then
                    error "Unknown field '${field}' - not defined in module-fields.json"
                    info "Valid fields:"
                    list_valid_fields | sed 's/^/    /'
                    exit 1
                fi

                # Update the JSON field (add or modify)
                local tmp_file
                tmp_file=$(mktemp)

                if should_be_number "${field}" "${value}"; then
                    # Validate it's actually a valid integer
                    if ! [[ "${value}" =~ ^-?[0-9]+$ ]]; then
                        rm -f "${tmp_file}"
                        die "Field '${field}' expects an integer, got '${value}'"
                    fi
                    # Store as number
                    if ! jq --arg f "${field}" --argjson v "${value}" '.[$f] = $v' "${dest_json}" > "${tmp_file}"; then
                        rm -f "${tmp_file}"
                        die "Failed to update field '${field}' with value '${value}'"
                    fi
                else
                    # Store as string
                    if ! jq --arg f "${field}" --arg v "${value}" '.[$f] = $v' "${dest_json}" > "${tmp_file}"; then
                        rm -f "${tmp_file}"
                        die "Failed to update field '${field}' with value '${value}'"
                    fi
                fi

                mv "${tmp_file}" "${dest_json}"
                info "  Set ${field} = ${value}"
                has_modifications=true
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    # Create .orig backup if modifications were made
    if [[ "${has_modifications}" == "true" ]]; then
        if [[ ! -f "${orig_json}" ]]; then
            info "Creating backup: ${orig_json}"
            cp "${source_json}" "${orig_json}"
        fi
    fi

    # Final validation
    if ! jq empty "${dest_json}" 2>/dev/null; then
        die "Resulting JSON is invalid: ${dest_json}"
    fi

    info "Successfully created ${dest_json}"
}

main "$@"
