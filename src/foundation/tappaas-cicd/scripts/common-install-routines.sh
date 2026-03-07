# common-install-routines.sh — Shared library for TAPPaaS-CICD scripts.
#
# This file should be sourced (.) into other scripts.
#
# Provides: color definitions, logging functions (info, warn, error, die),
# helper functions (get_module_dir, ensure_scripts_executable,
# check_service_available, validate_provided_services), JSON config loading
# (get_config_value, check_json).
#
# JSON auto-loading: If $1 is set when this file is sourced, the module
# JSON config is loaded automatically (from CONFIG_DIR or cwd) into the
# $JSON variable for use with get_config_value.  If $1 is empty or the
# config file does not exist, loading is silently skipped.

# ── Color definitions (only set if not already defined) ──────────────

[[ -z "${YW:-}" ]]   && YW=$'\033[33m'      # Yellow
[[ -z "${BL:-}" ]]   && BL=$'\033[36m'      # Cyan
[[ -z "${RD:-}" ]]   && RD=$'\033[01;31m'   # Red
[[ -z "${BGN:-}" ]]  && BGN=$'\033[4;92m'   # Bright Green with underline
[[ -z "${GN:-}" ]]   && GN=$'\033[1;92m'    # Green with bold
[[ -z "${DGN:-}" ]]  && DGN=$'\033[32m'     # Green
[[ -z "${CL:-}" ]]   && CL=$'\033[m'        # Clear
[[ -z "${BOLD:-}" ]] && BOLD=$'\033[1m'     # Bold

# ── Standard config directory ────────────────────────────────────────

[[ -z "${CONFIG_DIR:-}" ]] && CONFIG_DIR="/home/tappaas/config"

# ── Logging functions ────────────────────────────────────────────────

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Shared helper functions ──────────────────────────────────────────

# Get the module directory from the .location field in its deployed config JSON.
# Arguments: <module-name>
# Outputs the absolute directory path or returns 1 if not found.
get_module_dir() {
    local module="$1"
    local module_json="${CONFIG_DIR}/${module}.json"

    if [[ ! -f "${module_json}" ]]; then
        return 1
    fi

    local location
    location=$(jq -r '.location // empty' "${module_json}" 2>/dev/null)

    if [[ -z "${location}" ]]; then
        return 1
    fi

    echo "${location}"
    return 0
}

# Make all .sh scripts in a module directory executable.
# Handles: root-level scripts (install.sh, update.sh, pre-update.sh, etc.)
# and service scripts (services/*/install-service.sh, update-service.sh, etc.).
ensure_scripts_executable() {
    local dir="$1"

    if [[ ! -d "${dir}" ]]; then
        return 0
    fi

    # Root-level .sh files
    for script in "${dir}"/*.sh; do
        if [[ -f "${script}" ]]; then
            chmod +x "${script}"
        fi
    done

    # Service scripts
    for script in "${dir}"/services/*/*.sh; do
        if [[ -f "${script}" ]]; then
            chmod +x "${script}"
        fi
    done
}

# Check whether a dependency service is available from an installed provider.
# Validates: provider installed, service declared in provides, service directory
# exists, and the required script is present and executable.
#
# Arguments:
#   $1  Dependency reference in "module:service" format (e.g. "cluster:vm")
#   $2  (optional) Script name to check for (default: "install-service.sh")
#
# Returns 0 if the service is available, 1 otherwise.
check_service_available() {
    local dep="$1"
    local required_script="${2:-install-service.sh}"
    local provider_module="${dep%%:*}"
    local service_name="${dep##*:}"
    local provider_json="${CONFIG_DIR}/${provider_module}.json"

    # Check the provider module is installed (JSON in config dir)
    if [[ ! -f "${provider_json}" ]]; then
        error "Dependency '${dep}': provider module '${provider_module}' is not installed"
        error "  Expected config: ${provider_json}"
        return 1
    fi

    # Check the provider declares this service in its provides array
    if ! jq -e --arg svc "${service_name}" '.provides // [] | index($svc) != null' "${provider_json}" >/dev/null 2>&1; then
        error "Dependency '${dep}': module '${provider_module}' does not provide service '${service_name}'"
        return 1
    fi

    # Check the provider has the service directory and scripts
    local provider_dir
    if ! provider_dir=$(get_module_dir "${provider_module}"); then
        error "Dependency '${dep}': cannot find location for '${provider_module}' (missing .location in config)"
        return 1
    fi

    local svc_dir="${provider_dir}/services/${service_name}"
    if [[ ! -d "${svc_dir}" ]]; then
        error "Dependency '${dep}': service directory not found: ${svc_dir}"
        return 1
    fi

    if [[ ! -x "${svc_dir}/${required_script}" ]]; then
        error "Dependency '${dep}': missing or non-executable ${required_script} in ${svc_dir}"
        return 1
    fi

    return 0
}

# Validate that the module has service scripts for every service it provides.
# Arguments:
#   $1  Module directory (absolute path)
#   $2  Module JSON config file path
# Returns the number of errors found (0 = valid).
validate_provided_services() {
    local module_dir="$1"
    local module_json="$2"
    local errors=0

    local provides
    provides=$(jq -r '.provides // [] | .[]' "${module_json}" 2>/dev/null)

    for service in ${provides}; do
        local svc_dir="${module_dir}/services/${service}"

        if [[ ! -d "${svc_dir}" ]]; then
            error "Module provides '${service}' but directory not found: ${svc_dir}"
            ((errors++))
            continue
        fi

        if [[ ! -x "${svc_dir}/install-service.sh" ]]; then
            error "Module provides '${service}' but missing install-service.sh in ${svc_dir}"
            ((errors++))
        fi

        if [[ ! -x "${svc_dir}/update-service.sh" ]]; then
            error "Module provides '${service}' but missing update-service.sh in ${svc_dir}"
            ((errors++))
        fi
    done

    return "${errors}"
}

# ── Auto-load JSON configuration ─────────────────────────────────────
# If $1 (module/vm name) is provided, attempt to load its JSON config
# into the $JSON variable.  Silently skipped when $1 is empty or the
# config file does not exist (callers that need get_config_value but
# don't pass a module name via $1 can load JSON themselves after sourcing).

if [[ -n "${1:-}" ]]; then
    JSON_CONFIG="${CONFIG_DIR}/${1}.json"
    if [[ -f "${JSON_CONFIG}" ]]; then
        JSON=$(cat "${JSON_CONFIG}")
    elif [[ -f "${1}.json" ]]; then
        cp "${1}.json" "${JSON_CONFIG}"
        JSON=$(cat "${JSON_CONFIG}")
    fi
fi

# ── Config access ────────────────────────────────────────────────────

# Read a value from the loaded JSON config (requires $JSON to be set).
# Arguments: <key> [default-value]
function get_config_value() {
  local key="$1"
  local default="${2:-}"
  if ! echo "$JSON" | jq -e --arg K "$key" 'has($K)' >/dev/null ; then
    # JSON lacks the key
    if [ -z "$default" ]; then
      echo -e "\n${RD}[ERROR]${CL} Missing required key '${YW}$key${CL}' in JSON configuration." >&2
      exit 1
    else
      value="$default"
    fi
  else
    value=$(echo "$JSON" | jq -r --arg KEY "$key" '.[$KEY]')
  fi
  info "     - $key has value: ${BGN}${value}" >&2
  echo -n "${value}"
  return 0
}

# Validate a module JSON file against module-fields.json schema
# Usage: check_json <json_file> [schema_file]
# Returns: 0 if valid, 1 if errors found
# Outputs: Validation messages to stderr
function check_json() {
  local json_file="$1"
  local schema_file="${2:-/home/tappaas/TAPPaaS/src/foundation/module-fields.json}"
  local errors=0
  local warnings=0

  # Check if files exist
  if [ ! -f "$json_file" ]; then
    echo -e "${RD}[ERROR]${CL} JSON file not found: ${YW}$json_file${CL}" >&2
    return 1
  fi

  if [ ! -f "$schema_file" ]; then
    echo -e "${RD}[ERROR]${CL} Schema file not found: ${YW}$schema_file${CL}" >&2
    return 1
  fi

  # Parse the JSON file
  local json_content
  if ! json_content=$(jq '.' "$json_file" 2>&1); then
    echo -e "${RD}[ERROR]${CL} Invalid JSON syntax in ${YW}$json_file${CL}" >&2
    echo -e "       ${json_content}" >&2
    return 1
  fi

  # Load schema fields
  local schema_fields
  schema_fields=$(jq '.fields' "$schema_file")

  echo -e "${BL}Validating:${CL} $json_file" >&2

  # Check fields required by dependencies (requiredBy vs dependsOn)
  local depends_on_json
  depends_on_json=$(echo "$json_content" | jq -c '.dependsOn // []')

  local required_fields
  required_fields=$(echo "$schema_fields" | jq -r --argjson deps "$depends_on_json" '
    to_entries[] |
    select((.value.requiredBy // []) as $rb |
      ($rb | length > 0) and ([$rb[] as $r | $deps[] | select(. == $r)] | length > 0)) |
    .key')

  for field in $required_fields; do
    if ! echo "$json_content" | jq -e --arg F "$field" 'has($F)' >/dev/null 2>&1; then
      local req_by
      req_by=$(echo "$schema_fields" | jq -r --arg F "$field" --argjson deps "$depends_on_json" '
        .[$F].requiredBy as $rb | [$rb[] as $r | $deps[] | select(. == $r)] | join(", ")')
      echo -e "  ${RD}[ERROR]${CL} Missing field: ${YW}$field${CL} (required by ${req_by})" >&2
      ((errors++))
    fi
  done

  # Validate each field present in the JSON
  local json_keys
  json_keys=$(echo "$json_content" | jq -r 'keys[]')

  for key in $json_keys; do
    # Skip comment fields (start with -)
    if [[ "$key" == -* ]]; then
      continue
    fi

    # Check if field is defined in schema
    if ! echo "$schema_fields" | jq -e --arg K "$key" 'has($K)' >/dev/null 2>&1; then
      echo -e "  ${YW}[WARN]${CL} Unknown field: ${YW}$key${CL} (not in schema)" >&2
      ((warnings++))
      continue
    fi

    # Get field value and schema definition
    local value
    value=$(echo "$json_content" | jq -r --arg K "$key" '.[$K]')
    local field_schema
    field_schema=$(echo "$schema_fields" | jq --arg K "$key" '.[$K]')
    local field_type
    field_type=$(echo "$field_schema" | jq -r '.type')

    # Type validation
    case "$field_type" in
      "integer")
        if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
          echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: expected integer, got '${value}'" >&2
          ((errors++))
        else
          # Check minimum
          local min
          min=$(echo "$field_schema" | jq -r '.minimum // empty')
          if [ -n "$min" ] && [ "$value" -lt "$min" ]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: value $value is below minimum $min" >&2
            ((errors++))
          fi
          # Check maximum
          local max
          max=$(echo "$field_schema" | jq -r '.maximum // empty')
          if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: value $value exceeds maximum $max" >&2
            ((errors++))
          fi
        fi
        ;;

      "string")
        # Check pattern if defined
        local pattern
        pattern=$(echo "$field_schema" | jq -r '.pattern // empty')
        if [ -n "$pattern" ]; then
          if ! [[ "$value" =~ $pattern ]]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: value '${value}' does not match pattern '${pattern}'" >&2
            ((errors++))
          fi
        fi

        # Check format if defined (regexp-based format validation)
        local format
        format=$(echo "$field_schema" | jq -r '.format // empty')
        if [ -n "$format" ]; then
          if ! [[ "$value" =~ $format ]]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: value '${value}' does not match format '${format}'" >&2
            ((errors++))
          fi
        fi

        # Check allowed values if defined
        local allowed_values
        allowed_values=$(echo "$field_schema" | jq -r '.values // empty')
        if [ -n "$allowed_values" ] && [ "$allowed_values" != "null" ]; then
          local valid_values
          valid_values=$(echo "$allowed_values" | jq -r 'keys[]' 2>/dev/null || echo "$allowed_values" | jq -r '.[]' 2>/dev/null)
          local is_valid=0
          for valid in $valid_values; do
            if [ "$value" == "$valid" ]; then
              is_valid=1
              break
            fi
          done
          if [ $is_valid -eq 0 ]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: invalid value '${value}'" >&2
            echo -e "           Allowed values: ${valid_values//$'\n'/, }" >&2
            ((errors++))
          fi
        fi
        ;;
    esac
  done

  # Cross-field validations
  local image_type
  image_type=$(echo "$json_content" | jq -r '.imageType // "clone"')

  # Check imageLocation is present for iso/img types
  if [[ "$image_type" == "iso" || "$image_type" == "img" ]]; then
    if ! echo "$json_content" | jq -e 'has("imageLocation")' >/dev/null 2>&1; then
      echo -e "  ${RD}[ERROR]${CL} Field ${YW}imageLocation${CL} is required when imageType is '${image_type}'" >&2
      ((errors++))
    fi
  fi

  # Check HANode is different from node if specified
  local ha_node
  ha_node=$(echo "$json_content" | jq -r '.HANode // "NONE"')
  local node
  node=$(echo "$json_content" | jq -r '.node // "tappaas1"')
  if [ "$ha_node" != "NONE" ] && [ "$ha_node" == "$node" ]; then
    echo -e "  ${RD}[ERROR]${CL} HANode (${ha_node}) must be different from node (${node})" >&2
    ((errors++))
  fi

  # Check zone references exist in zones.json
  local zones_file="/home/tappaas/config/zones.json"
  if [ -f "$zones_file" ]; then
    for zone_field in zone0 zone1; do
      local zone_value
      zone_value=$(echo "$json_content" | jq -r --arg Z "$zone_field" '.[$Z] // empty')
      if [ -n "$zone_value" ]; then
        if ! jq -e --arg Z "$zone_value" 'has($Z)' "$zones_file" >/dev/null 2>&1; then
          echo -e "  ${RD}[ERROR]${CL} Field ${YW}$zone_field${CL}: zone '${zone_value}' not found in zones.json" >&2
          ((errors++))
        fi
      fi
    done
  fi

  # Summary
  echo "" >&2
  if [ $errors -gt 0 ]; then
    echo -e "${RD}Validation failed:${CL} $errors error(s), $warnings warning(s)" >&2
    return 1
  elif [ $warnings -gt 0 ]; then
    echo -e "${YW}Validation passed with warnings:${CL} $warnings warning(s)" >&2
    return 0
  else
    echo -e "${GN}Validation passed:${CL} No errors or warnings" >&2
    return 0
  fi
}
