# This file contains common installation routines for TAPPaaS-CICD related install scripts.
# It should be sourced (.) into the install scripts.
# It assumes that you are in the install directory of the module being installed.
#

# Color definitions
YW=$(echo "\033[33m")    # Yellow
BL=$(echo "\033[36m")    # Cyan
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
GN=$(echo "\033[1;92m")  # Green with bold
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
BOLD=$(echo "\033[1m")   # Bold

function info() {
  local msg="$1"
  echo -e "${DGN}${msg}${CL}"
}

function warn() {
  local msg="$1"
  echo -e "${YW}${msg}${CL}"
}

function error() {
  local msg="$1"
  echo -e "${RD}[ERROR]${CL} ${msg}"
}

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

# validate argument
if [ -z "$1" ]; then
  echo "Usage: $0 <vmname>"
  echo "A JSON configuration file is expected at: /home/tappaas/config/<vmname>.json or in current directory as ./<vmname>.json"
  exit 1
fi

# load JSON configuration
JSON_CONFIG="/home/tappaas/config/$1.json"
if [ ! -f "$JSON_CONFIG" ]; then
  # use the file in the current directory as fallback
  if [ ! -f "$1.json" ]; then
    echo -e "\n${RD}[ERROR]${CL} Configuration file not found: ${YW}$JSON_CONFIG${CL}"
    echo -e "Also checked: ${YW}$1.json${CL} in current directory"
    exit 1
  fi
  cp "$1.json" "$JSON_CONFIG"
fi
JSON=$(cat "$JSON_CONFIG")

function get_config_value() {
  local key="$1"
  local default="$2"
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
  local schema_file="${2:-/home/tappaas/config/module-fields.json}"
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

  # Check required fields
  local required_fields
  required_fields=$(echo "$schema_fields" | jq -r 'to_entries[] | select(.value.required == true) | .key')

  for field in $required_fields; do
    if ! echo "$json_content" | jq -e --arg F "$field" 'has($F)' >/dev/null 2>&1; then
      echo -e "  ${RD}[ERROR]${CL} Missing required field: ${YW}$field${CL}" >&2
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
