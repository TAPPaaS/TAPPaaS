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
