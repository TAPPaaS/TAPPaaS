#!/usr/bin/env bash
#
# Copy a module JSON file to config directory and update fields.
#
# Usage: copy-update-json.sh <module-name> [--variant <name>] [--<field> <value>]...
#
# Example:
#   copy-update-json.sh identity --node "tappaas2" --cores 4
#   copy-update-json.sh openwebui --variant staging
#   copy-update-json.sh openwebui --variant dev --zone0 srv-dev --vmid 315
#
# This script:
#   1. Copies <module>.json from current directory to /home/tappaas/config/
#      (or <module>-<variant>.json when --variant is used)
#   2. Automatically sets the 'location' field to the module directory
#   3. Validates field names against module-fields.json schema
#   4. When --variant is used, applies variant defaults (see below)
#   5. Modifies the copied JSON based on --<field> <value> arguments
#   6. Creates a .orig backup if modifications are made
#   7. Validates the resulting JSON
#
# Variant mode (--variant <name>):
#   Output JSON is named <module>-<variant>.json. Fields are derived
#   automatically unless explicitly overridden with --<field>:
#     vmname       → <source vmname>-<variant>
#     vmid         → next available VMID after the source VMID
#     zone0        → <variant> if it matches a zone in zones.json, else unchanged
#     proxyDomain  → "name.<variant>.domain" (inserts variant after first segment)
#

set -euo pipefail

# Use conditional assignment so variables are safe both when run directly
# and when sourced by another script (e.g., install-module.sh).
: "${SCRIPT_NAME:=$(basename "${BASH_SOURCE[0]}")}"
: "${CONFIG_DIR:=/home/tappaas/config}"
: "${YW:=$'\033[33m'}"
: "${RD:=$'\033[01;31m'}"
: "${DGN:=$'\033[32m'}"
: "${CL:=$'\033[m'}"
SCHEMA_FILE="/home/tappaas/TAPPaaS/src/foundation/module-fields.json"

# Source common-install-routines.sh if not already loaded (provides info, warn, error, die)
if ! declare -F info &>/dev/null; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        . /home/tappaas/bin/common-install-routines.sh
    else
        # Minimal fallback for bootstrap before common-install-routines.sh exists
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$@"; exit 1; }
    fi
fi

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <module-name> [--variant <name>] [--<field> <value>]...

Copy a module JSON file to the config directory and optionally update fields.

Arguments:
    module-name         Name of the module (expects ./<module-name>.json to exist)

Options:
    --variant <name>    Create a variant of the module (output: <module>-<name>.json)
    --<field> <value>   Set JSON field to value (can be repeated)
    -h, --help          Show this help message

Examples:
    ${SCRIPT_NAME} identity
    ${SCRIPT_NAME} identity --node "tappaas2" --cores 4
    ${SCRIPT_NAME} nextcloud --memory 4096 --zone0 "trusted"
    ${SCRIPT_NAME} openwebui --variant staging
    ${SCRIPT_NAME} openwebui --variant dev --zone0 srv-dev --vmid 315

Variant mode:
    When --variant is used, the output JSON is named <module>-<variant>.json.
    The following fields are derived automatically unless explicitly overridden:
      vmname       → <source vmname>-<variant>
      vmid         → next available VMID after the source module's VMID
      zone0        → <variant> if it matches a zone name in zones.json, else unchanged
      proxyDomain  → inserts <variant> after first segment (e.g. app.example.com → app.<variant>.example.com)

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

# Find the next available VMID after source_vmid by scanning config and modules.json
find_next_vmid() {
    local source_vmid="$1"
    local used_vmids=""

    # Collect VMIDs from config directory
    local f
    for f in "${CONFIG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        local vid
        vid=$(jq -r '.vmid // empty' "$f" 2>/dev/null)
        [[ -n "$vid" ]] && used_vmids="${used_vmids} ${vid}"
    done

    # Collect VMIDs from modules.json
    local modules_json="/home/tappaas/TAPPaaS/src/modules.json"
    if [[ -f "${modules_json}" ]]; then
        local vid
        for vid in $(jq -r '.. | .vmid? // empty' "${modules_json}" 2>/dev/null); do
            used_vmids="${used_vmids} ${vid}"
        done
    fi

    # Find next available starting from source_vmid + 1
    local candidate=$((source_vmid + 1))
    while echo " ${used_vmids} " | grep -q " ${candidate} "; do
        candidate=$((candidate + 1))
    done

    echo "${candidate}"
}

# Apply variant defaults for fields not explicitly overridden
apply_variant_defaults() {
    local variant="$1"
    local dest_json="$2"
    local has_vmname="$3"
    local has_vmid="$4"
    local has_zone0="$5"
    local has_proxydomain="$6"

    local tmp_file

    # 1. vmname: append -<variant> to source vmname
    if [[ "${has_vmname}" == "false" ]]; then
        local src_vmname
        src_vmname=$(jq -r '.vmname // empty' "${dest_json}")
        if [[ -n "${src_vmname}" ]]; then
            local new_vmname="${src_vmname}-${variant}"
            tmp_file=$(mktemp)
            jq --arg v "${new_vmname}" '.vmname = $v' "${dest_json}" > "${tmp_file}"
            mv "${tmp_file}" "${dest_json}"
            info "  Variant: vmname = ${new_vmname}"
        fi
    fi

    # 2. vmid: auto-increment to next available
    if [[ "${has_vmid}" == "false" ]]; then
        local src_vmid
        src_vmid=$(jq -r '.vmid // empty' "${dest_json}")
        if [[ -n "${src_vmid}" ]]; then
            local next_vmid
            next_vmid=$(find_next_vmid "${src_vmid}")
            tmp_file=$(mktemp)
            jq --argjson v "${next_vmid}" '.vmid = $v' "${dest_json}" > "${tmp_file}"
            mv "${tmp_file}" "${dest_json}"
            info "  Variant: vmid = ${next_vmid}"
        fi
    fi

    # 3. zone0: use variant name if it matches a zone in zones.json
    if [[ "${has_zone0}" == "false" ]]; then
        local zones_file="/home/tappaas/TAPPaaS/src/foundation/firewall/zones.json"
        # Also check deployed copy
        [[ ! -f "${zones_file}" ]] && zones_file="/home/tappaas/config/zones.json"
        if [[ -f "${zones_file}" ]] && jq -e --arg z "${variant}" 'has($z)' "${zones_file}" >/dev/null 2>&1; then
            tmp_file=$(mktemp)
            jq --arg v "${variant}" '.zone0 = $v' "${dest_json}" > "${tmp_file}"
            mv "${tmp_file}" "${dest_json}"
            info "  Variant: zone0 = ${variant} (matched zone name)"
        fi
    fi

    # 4. proxyDomain: transform "name.domain" to "name.<variant>.domain"
    if [[ "${has_proxydomain}" == "false" ]]; then
        local src_domain
        src_domain=$(jq -r '.proxyDomain // empty' "${dest_json}")
        if [[ -n "${src_domain}" && "${src_domain}" == *.* ]]; then
            local name="${src_domain%%.*}"
            local domain="${src_domain#*.}"
            local new_domain="${name}.${variant}.${domain}"
            tmp_file=$(mktemp)
            jq --arg v "${new_domain}" '.proxyDomain = $v' "${dest_json}" > "${tmp_file}"
            mv "${tmp_file}" "${dest_json}"
            info "  Variant: proxyDomain = ${new_domain}"
        fi
    fi
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

    # ── Pre-scan arguments for --variant and track explicit overrides ──
    local variant=""
    local has_explicit_vmname=false
    local has_explicit_vmid=false
    local has_explicit_zone0=false
    local has_explicit_proxydomain=false
    local filtered_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant)
                [[ -z "${2:-}" ]] && die "Option --variant requires a value"
                variant="$2"
                shift 2
                ;;
            --vmname)
                has_explicit_vmname=true
                filtered_args+=("$1" "$2")
                shift 2
                ;;
            --vmid)
                has_explicit_vmid=true
                filtered_args+=("$1" "$2")
                shift 2
                ;;
            --zone0)
                has_explicit_zone0=true
                filtered_args+=("$1" "$2")
                shift 2
                ;;
            --proxyDomain)
                has_explicit_proxydomain=true
                filtered_args+=("$1" "$2")
                shift 2
                ;;
            --*)
                [[ -z "${2:-}" ]] && die "Option $1 requires a value"
                filtered_args+=("$1" "$2")
                shift 2
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    # Restore filtered args (without --variant)
    set -- "${filtered_args[@]+${filtered_args[@]}}"

    # Determine effective module name
    local effective_module="${module}"
    if [[ -n "${variant}" ]]; then
        effective_module="${module}-${variant}"
        info "Variant mode: ${module} → ${effective_module}"
    fi

    # Export for callers that source this script (e.g., install-module.sh)
    EFFECTIVE_MODULE="${effective_module}"

    local source_json="./${module}.json"
    local dest_json="${CONFIG_DIR}/${effective_module}.json"
    local orig_json="${CONFIG_DIR}/${effective_module}.json.orig"

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

    # Internal pipeline (#207): work on the flat representation throughout this
    # function so overrides land cleanly. The dest_json is re-rendered in the
    # canonical Pattern A shape as the very last step (see the regroup block
    # at the end of this function). If the source uses a Pattern-A config
    # block, flatten it up to top now.
    if declare -F normalize_module_config >/dev/null 2>&1 \
       && jq -e '(.config | type) == "object"' "${dest_json}" >/dev/null 2>&1; then
        info "  Flattening Pattern-A config block for internal processing"
        local norm_tmp
        norm_tmp=$(mktemp)
        if normalize_module_config < "${dest_json}" > "${norm_tmp}" && jq empty "${norm_tmp}" 2>/dev/null; then
            mv "${norm_tmp}" "${dest_json}"
        else
            rm -f "${norm_tmp}"
            die "Failed to flatten Pattern-A config block in ${source_json}"
        fi
    fi

    # Copy the optional <module>.meta.json alongside it (cluster:lxc reads this
    # for GPU passthrough / bind-mounts; not schema-validated). Issue #203.
    local source_meta="./${module}.meta.json"
    if [[ -f "${source_meta}" ]]; then
        local dest_meta="${CONFIG_DIR}/${effective_module}.meta.json"
        info "Copying ${source_meta} to ${dest_meta}"
        cp "${source_meta}" "${dest_meta}"
    fi

    # Get the absolute path of the module directory (where the source JSON resides)
    local module_dir
    module_dir="$(cd "$(dirname "${source_json}")" && pwd)"

    # Automatically set location, installTime, and releaseDate (if missing)
    local tmp_file install_time release_date
    install_time=$(date +'%Y%m%d-%H:%M:%S')
    release_date=$(date +'%Y-%m-%d')
    tmp_file=$(mktemp)
    if ! jq --arg loc "${module_dir}" \
            --arg t "${install_time}" \
            --arg rd "${release_date}" \
            '.location = $loc | .installTime = $t | if .releaseDate == null or .releaseDate == "" then .releaseDate = $rd else . end' \
            "${dest_json}" > "${tmp_file}"; then
        rm -f "${tmp_file}"
        die "Failed to set auto-populated fields"
    fi
    mv "${tmp_file}" "${dest_json}"
    info "  Set location = ${module_dir}"
    info "  Set installTime = ${install_time}"
    # Check if releaseDate was auto-populated
    if ! jq -e '.releaseDate' "${source_json}" >/dev/null 2>&1; then
        info "  Set releaseDate = ${release_date} (auto-populated)"
    fi

    # ── Apply variant defaults (before explicit overrides) ───────────
    if [[ -n "${variant}" ]]; then
        info "Applying variant defaults..."
        apply_variant_defaults "${variant}" "${dest_json}" \
            "${has_explicit_vmname}" "${has_explicit_vmid}" \
            "${has_explicit_zone0}" "${has_explicit_proxydomain}"
        # Persist the variant name on the installed config so update-module.sh
        # can resolve the correct source file (#207). The variant field is
        # treated as auto-managed by the 3-way merge — never adopted from
        # the release source.
        tmp_file=$(mktemp)
        if jq --arg v "${variant}" '.variant = $v' "${dest_json}" > "${tmp_file}"; then
            mv "${tmp_file}" "${dest_json}"
            info "  Persisted variant = ${variant}"
        else
            rm -f "${tmp_file}"
            warn "  Could not persist variant field"
        fi
    fi

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

    # Validate that the target node is reachable
    local node
    node=$(jq -r '.node // empty' "${dest_json}" 2>/dev/null)
    if [[ -n "${node}" ]]; then
        local default_node
        default_node="$(get_node_hostname 0)"
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${node}.mgmt.internal" "true" >/dev/null 2>&1; then
            warn "Node '${node}' is not reachable - reassigning to '${default_node}'"
            local tmp_file
            tmp_file=$(mktemp)
            if jq --arg n "${default_node}" '.node = $n' "${dest_json}" > "${tmp_file}"; then
                mv "${tmp_file}" "${dest_json}"
            else
                rm -f "${tmp_file}"
            fi
        fi
    fi

    # Render in canonical Pattern A on disk (#207). The converter also reorders
    # top-level keys per .fieldOrder and reorders config sub-blocks, so the
    # explicit reorder step that used to live here is no longer needed.
    local convert_cli=""
    for _cv in /home/tappaas/bin/convert-json-to-config.sh \
               "$(dirname "${BASH_SOURCE[0]}")/convert-json-to-config.sh"; do
        [[ -f "$_cv" ]] && { convert_cli="$_cv"; break; }
    done
    if [[ -n "${convert_cli}" ]]; then
        info "  Rendering canonical Pattern A on disk (#207)"
        local pa_tmp
        pa_tmp=$(mktemp)
        if "${convert_cli}" "${dest_json}" > "${pa_tmp}" 2>/dev/null && jq empty "${pa_tmp}" 2>/dev/null; then
            mv "${pa_tmp}" "${dest_json}"
        else
            rm -f "${pa_tmp}"
            die "Failed to render canonical Pattern A for ${source_json}"
        fi
    else
        warn "convert-json-to-config.sh not found — installed config will retain flat shape"
    fi

    # Final validation
    if ! jq empty "${dest_json}" 2>/dev/null; then
        die "Resulting JSON is invalid: ${dest_json}"
    fi

    info "Successfully created ${dest_json}"
}

main "$@"
