# This file contain common installation routines for TAPPaaS-CICD related install scripts.
# it should be sources (.) into the install scripts
# It assume that you are in the install directory of the module being installed.

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

function info() {
  local msg="$1"
  echo -e "${DGN}${msg}${CL}"
}

YW=$(echo "\033[33m")    # Yellow
BL=$(echo "\033[36m")    # Cyan
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
GN=$(echo "\033[1;92m")  # Green with bold
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
BOLD=$(echo "\033[1m")   # Bold

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
    value=$(echo $JSON | jq -r --arg KEY "$key" '.[$KEY]')
  fi
  info "     - $key has value: ${BGN}${value}" >&2 #TODO, this is a hack using std error for info logging
  echo -n "${value}"
  return 0
}

# test to see if the json config file exist
# first test if there is an argument
if [ -z "$1" ]; then
  echo -e "\n${RD}[ERROR]${CL} Missing required argument VMNAME."
  exit 1
fi

JSON_CONFIG="/home/tappaas/config/$1.json"
if [ -z "$JSON_CONFIG" ]; then
  # use the file in the current directory as fallback
  if [ ! -f "$1.json" ]; then
    echo -e "\n${RD}[ERROR]${CL} Missing argument or missing .json for VMNAME. Current value: '$1'"
    exit 1
  fi
  cp "$1.json" "$JSON_CONFIG"
fi
JSON=$(cat $JSON_CONFIG)


