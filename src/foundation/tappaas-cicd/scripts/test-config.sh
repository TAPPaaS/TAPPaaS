#!/usr/bin/env bash
# test the TAPPaaS installation
#
# It will run through a number of test, each either just be a status line OR it will haev a warning/failure message
# if something is wrong.
# details can be found in /home/tappaas/logs/test-config.log

# Color definitions
YW=$(echo "\033[33m")    # Yellow
BL=$(echo "\033[36m")    # Cyan
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
GN=$(echo "\033[1;92m")  # Green with bold
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
BOLD=$(echo "\033[1m")   # Bold
BFR="\\r\\033[K"

msg_headline() {
  echo -e "${CL}${BOLD}========================================"
  echo -e "$1"
  echo -e "========================================${CL}"
}

msg_testing() {
  test_msg="$1"
  echo -ne "${YW}Testing: ${test_msg}..."
}

msg_ok() {
  echo -e "${GN}${msg}Success: ${CL}"
}

msg_warning() {
  echo -e "${BFR}${BOLD}${BL}Warning: ${msg}${CL}"
  echo "Warning: $msg" >> "$LOGFILE"
}

msg_error() {
  echo -e "${BFR}${BOLD}${RD}Error:   ${msg}${CL}"
  echo "Error: $msg" >> "$LOGFILE"
}

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

#TODO , make automatic use of LOGFILE in above functions
LOGFILE="/home/tappaas/logs/test-config.log"
mkdir -p /home/tappaas/logs
echo "TAPPaaS-CICD Test Log" > "$LOGFILE"
echo "======================" >> "$LOGFILE"
echo "" >> "$LOGFILE"

msg_headline "Testing TAPPaaS-CICD Installation"

msg_testing "Do the tappaas user exists"
if id "tappaas" &>/dev/null; then
  msg_ok
else
  msg_error
fi  

msg_testing "Do the SSH keys exist for tappaas user"
if [ -f "/home/tappaas/.ssh/id_rsa" ] && [ -f "/home/tappaas/.ssh/id_rsa.pub" ]; then
  msg_ok
else
  msg_error
fi

msg_testing "Is the tappaas-cicd repo cloned"
if [ -d "/home/tappaas/TAPPaaS" ]; then
  msg_ok
else
  msg_error
fi  
msg_testing "Is the NixOS configuration applied"
if [ -f "/etc/nixos/tappaas-cicd.nix" ]; then
  msg_ok
else
  msg_error
fi  
msg_headline "Validating Module JSON Configurations"

# Source common-install-routines for check_json function (bypass hostname check)
# We inline the necessary parts to avoid the hostname check and argument validation
source_check_json() {
  # Color definitions (already defined above)

  # Validate a module JSON file against module-fields.json schema
  # Usage: check_json <json_file> [schema_file]
  # Returns: 0 if valid, 1 if errors found
  check_json() {
    local json_file="$1"
    local schema_file="${2:-/home/tappaas/config/module-fields.json}"
    local errors=0
    local warnings=0

    if [ ! -f "$json_file" ]; then
      echo -e "${RD}[ERROR]${CL} JSON file not found: ${YW}$json_file${CL}" >&2
      return 1
    fi

    if [ ! -f "$schema_file" ]; then
      echo -e "${RD}[ERROR]${CL} Schema file not found: ${YW}$schema_file${CL}" >&2
      return 1
    fi

    local json_content
    if ! json_content=$(jq '.' "$json_file" 2>&1); then
      echo -e "${RD}[ERROR]${CL} Invalid JSON syntax in ${YW}$json_file${CL}" >&2
      return 1
    fi

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
      [[ "$key" == -* ]] && continue

      if ! echo "$schema_fields" | jq -e --arg K "$key" 'has($K)' >/dev/null 2>&1; then
        echo -e "  ${YW}[WARN]${CL} Unknown field: ${YW}$key${CL}" >&2
        ((warnings++))
        continue
      fi

      local value field_schema field_type
      value=$(echo "$json_content" | jq -r --arg K "$key" '.[$K]')
      field_schema=$(echo "$schema_fields" | jq --arg K "$key" '.[$K]')
      field_type=$(echo "$field_schema" | jq -r '.type')

      case "$field_type" in
        "integer")
          if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: expected integer" >&2
            ((errors++))
          else
            local min max
            min=$(echo "$field_schema" | jq -r '.minimum // empty')
            max=$(echo "$field_schema" | jq -r '.maximum // empty')
            [ -n "$min" ] && [ "$value" -lt "$min" ] && { echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: below minimum $min" >&2; ((errors++)); }
            [ -n "$max" ] && [ "$value" -gt "$max" ] && { echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: exceeds maximum $max" >&2; ((errors++)); }
          fi
          ;;
        "string")
          local pattern
          pattern=$(echo "$field_schema" | jq -r '.pattern // empty')
          if [ -n "$pattern" ] && ! [[ "$value" =~ $pattern ]]; then
            echo -e "  ${RD}[ERROR]${CL} Field ${YW}$key${CL}: pattern mismatch" >&2
            ((errors++))
          fi
          ;;
      esac
    done

    # Cross-field validations
    local image_type ha_node node
    image_type=$(echo "$json_content" | jq -r '.imageType // "clone"')
    if [[ "$image_type" == "iso" || "$image_type" == "img" ]]; then
      if ! echo "$json_content" | jq -e 'has("imageLocation")' >/dev/null 2>&1; then
        echo -e "  ${RD}[ERROR]${CL} imageLocation required for imageType '${image_type}'" >&2
        ((errors++))
      fi
    fi

    ha_node=$(echo "$json_content" | jq -r '.HANode // "NONE"')
    node=$(echo "$json_content" | jq -r '.node // "tappaas1"')
    if [ "$ha_node" != "NONE" ] && [ "$ha_node" == "$node" ]; then
      echo -e "  ${RD}[ERROR]${CL} HANode must differ from node" >&2
      ((errors++))
    fi

    # Check zones
    local zones_file="/home/tappaas/config/zones.json"
    if [ -f "$zones_file" ]; then
      for zone_field in zone0 zone1; do
        local zone_value
        zone_value=$(echo "$json_content" | jq -r --arg Z "$zone_field" '.[$Z] // empty')
        if [ -n "$zone_value" ]; then
          if ! jq -e --arg Z "$zone_value" 'has($Z)' "$zones_file" >/dev/null 2>&1; then
            echo -e "  ${RD}[ERROR]${CL} Zone '${zone_value}' not in zones.json" >&2
            ((errors++))
          fi
        fi
      done
    fi

    if [ $errors -gt 0 ]; then
      echo -e "${RD}Failed:${CL} $errors error(s), $warnings warning(s)" >&2
      return 1
    elif [ $warnings -gt 0 ]; then
      echo -e "${YW}Passed with warnings:${CL} $warnings warning(s)" >&2
      return 0
    else
      echo -e "${GN}Passed${CL}" >&2
      return 0
    fi
  }
}

source_check_json

# Validate all module JSON files
json_errors=0
json_count=0

for json_file in /home/tappaas/config/*.json; do
  # Skip schema/field definition files
  basename=$(basename "$json_file")
  case "$basename" in
    *-fields.json|configuration.json|zones.json)
      continue
      ;;
  esac

  ((json_count++))
  if ! check_json "$json_file" 2>&1 | tee -a "$LOGFILE"; then
    ((json_errors++))
  fi
  echo "" >> "$LOGFILE"
done

echo ""
if [ $json_errors -gt 0 ]; then
  echo -e "${RD}JSON Validation: $json_errors of $json_count module(s) have errors${CL}"
else
  echo -e "${GN}JSON Validation: All $json_count module(s) passed validation${CL}"
fi

msg_headline "TAPPaaS-CICD Installation Test Completed"

echo -e "\nDetailed log can be found in $LOGFILE\n"
