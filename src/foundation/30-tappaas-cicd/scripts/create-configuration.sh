#!/usr/bin/env bash
#
# Create a configuration.json according to the configuration-fields.json for the current running TAPPaaS system
#
# Usage: ./create-configuration.sh "upstreamGit" "branch" "domain" "email" "updateSchedule" ["weekday"] ["hour"]
#
# Where
#   upstreamGit is the git URL of the upstream repository
#   branch is the branch to use for updates (e.g. main)
#   domain is the domain to use for the TAPPaaS system, typically mydomain.com (without www or @)
#   email is the email to use for reporting system status and issues, typically admin@mydomain
#   updateSchedule is the schedule for when to run the update script: monthly, weekly, daily, or none
#   weekday (optional) is the day of the week for updates (default: Thursday). Ignored for daily frequency.
#   hour (optional) is the hour of day (0-23) for updates (default: 2)
#
# the rest of the values in the configuration is derived from the running system. aka by listing the nodes we can determine how many in the cluster and what their names are, by listing the VMs we can determine which modules are installed and IP they have
#
# the generated configuration.json is stored in /home/tappaas/config
#
set -euo pipefail

# Color definitions
YW=$(echo "\033[33m")    # Yellow
BL=$(echo "\033[36m")    # Cyan
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
GN=$(echo "\033[1;92m")  # Green with bold
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
# Logging functions
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
  error "$*"
  exit 1
}

# Check for required commands
command -v jq >/dev/null 2>&1 || die "jq is required but not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is required but not installed."

# Usage function
usage() {
  cat << EOF
Usage: $(basename "$0") <upstreamGit> <branch> <domain> <email> <updateSchedule> [weekday] [hour]

Arguments:
  upstreamGit     Git URL of the upstream repository (e.g., github.com/TAPPaaS/TAPPaaS)
  branch          Branch to use for updates (e.g., main, stable, develop)
  domain          Primary domain for TAPPaaS (e.g., mytappaas.dev, without www or @)
  email           Admin email for SSL certificates and notifications
  updateSchedule  Update frequency: monthly, weekly, daily, or none
  weekday         (Optional) Day of week for updates (default: Thursday). Ignored for daily.
  hour            (Optional) Hour of day 0-23 for updates (default: 2)

Examples:
  $(basename "$0") github.com/TAPPaaS/TAPPaaS main mytappaas.dev admin@mytappaas.dev monthly
  $(basename "$0") github.com/TAPPaaS/TAPPaaS main mytappaas.dev admin@mytappaas.dev weekly Wednesday 3
  $(basename "$0") github.com/myorg/TAPPaaS develop mysite.com ops@mysite.com daily
EOF
}

# Validate arguments
if [ $# -lt 5 ]; then
  error "Missing required arguments."
  usage
  exit 1
fi

UPSTREAM_GIT="$1"
BRANCH="$2"
DOMAIN="$3"
EMAIL="$4"
UPDATE_SCHEDULE="$5"
UPDATE_WEEKDAY="${6:-Thursday}"
UPDATE_HOUR="${7:-2}"

# Validate updateSchedule
case "$UPDATE_SCHEDULE" in
  monthly|weekly|daily|none)
    ;;
  *)
    die "Invalid updateSchedule: '$UPDATE_SCHEDULE'. Must be one of: monthly, weekly, daily, none"
    ;;
esac

# Validate weekday
case "$UPDATE_WEEKDAY" in
  Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)
    ;;
  *)
    die "Invalid weekday: '$UPDATE_WEEKDAY'. Must be one of: Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday"
    ;;
esac

# Validate hour
if ! [[ "$UPDATE_HOUR" =~ ^[0-9]+$ ]] || [ "$UPDATE_HOUR" -lt 0 ] || [ "$UPDATE_HOUR" -gt 23 ]; then
  die "Invalid hour: '$UPDATE_HOUR'. Must be an integer between 0 and 23"
fi

# Validate email format (basic check)
if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  warn "Email '$EMAIL' may not be in a valid format."
fi

# Configuration file paths
CONFIG_DIR="/home/tappaas/config"
CONFIG_FILE="${CONFIG_DIR}/configuration.json"
MGMT="mgmt"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

info "Creating TAPPaaS configuration..."
info "  Upstream Git: ${BGN}${UPSTREAM_GIT}${CL}"
info "  Branch: ${BGN}${BRANCH}${CL}"
info "  Domain: ${BGN}${DOMAIN}${CL}"
info "  Email: ${BGN}${EMAIL}${CL}"
info "  Update Schedule: ${BGN}${UPDATE_SCHEDULE}, ${UPDATE_WEEKDAY}, hour ${UPDATE_HOUR}${CL}"
echo ""

# Get TAPPaaS version from git
TAPPAAS_VERSION="0.5"
if [ -f "/home/tappaas/TAPPaaS/.git/HEAD" ]; then
  # Try to get version tag or short commit hash
  cd /home/tappaas/TAPPaaS
  if git describe --tags --abbrev=0 2>/dev/null; then
    TAPPAAS_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.5")
  fi
  cd - >/dev/null
fi
info "TAPPaaS Version: ${BGN}${TAPPAAS_VERSION}${CL}"

# Discover Proxmox cluster nodes
info "Discovering Proxmox cluster nodes..."

# Try to get node list from any accessible Proxmox node
NODES=()
NODE_IPS=()

# First, try tappaas1 as the primary node
PRIMARY_NODE="tappaas1.${MGMT}.internal"

# Get list of cluster nodes via pvecm
CLUSTER_NODES=""
if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${PRIMARY_NODE}" "pvecm nodes" >/dev/null 2>&1; then
  # Parse pvecm nodes output - extract node names, skip header and empty lines
  CLUSTER_NODES=$(ssh "root@${PRIMARY_NODE}" "pvecm nodes 2>/dev/null | tail -n +2 | awk 'NF>=3 {print \$3}' | grep -v '^Name$' | grep -v '^-*$'" 2>/dev/null || true)
fi

# If pvecm failed, try pvesh with JSON format (more reliable)
if [ -z "$CLUSTER_NODES" ]; then
  info "  Trying pvesh to list nodes..."
  CLUSTER_NODES=$(ssh "root@${PRIMARY_NODE}" "pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[].node' | grep -v '^null$'" 2>/dev/null || true)
fi

# If still empty, fall back to just tappaas1
if [ -z "$CLUSTER_NODES" ]; then
  warn "Could not discover cluster nodes. Using tappaas1 as default."
  CLUSTER_NODES="tappaas1"
fi

info "  Found nodes: ${BGN}${CLUSTER_NODES}${CL}"

# Get IP addresses for each node
for node in $CLUSTER_NODES; do
  NODES+=("$node")

  # Try to get the management IP from the node
  NODE_IP=""
  NODE_FQDN="${node}.${MGMT}.internal"

  # Method 1: DNS lookup
  NODE_IP=$(getent hosts "$NODE_FQDN" 2>/dev/null | awk '{print $1}' | head -1 || true)

  # Method 2: Query the node directly
  if [ -z "$NODE_IP" ]; then
    NODE_IP=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_FQDN}" \
      "ip -4 addr show | grep -oP '(?<=inet\\s)10\\.0\\.0\\.[0-9]+' | head -1" 2>/dev/null || true)
  fi

  if [ -z "$NODE_IP" ]; then
    warn "Could not determine IP for node $node"
    NODE_IP="unknown"
  fi

  NODE_IPS+=("$NODE_IP")
  info "  ${node}: ${BGN}${NODE_IP}${CL}"
done

NODE_COUNT=${#NODES[@]}
info "Total nodes: ${BGN}${NODE_COUNT}${CL}"
echo ""

# Build the tappaas-nodes array
info "Building node configuration..."
NODES_JSON="["
FIRST_NODE=true

for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"
  ip="${NODE_IPS[$i]}"

  if [ "$FIRST_NODE" = true ]; then
    FIRST_NODE=false
  else
    NODES_JSON+=","
  fi

  NODES_JSON+=$(cat << NODEEOF
    {
      "hostname": "$node",
      "ip": "$ip"
    }
NODEEOF
)
done

NODES_JSON+="]"
echo ""

# Build the complete configuration JSON
info "Generating configuration.json..."

# Build the global updateSchedule
if [ "$UPDATE_SCHEDULE" = "daily" ]; then
  SCHEDULE_JSON="[\"daily\", null, ${UPDATE_HOUR}]"
else
  SCHEDULE_JSON="[\"${UPDATE_SCHEDULE}\", \"${UPDATE_WEEKDAY}\", ${UPDATE_HOUR}]"
fi

info "Global updateSchedule: ${BGN}${SCHEDULE_JSON}${CL}"

CONFIG_JSON=$(cat << EOF
{
  "-comment1": "TAPPaaS Configuration - Generated $(date '+%Y-%m-%d %H:%M:%S')",
  "-comment2": "Edit this file at ${CONFIG_FILE}, changes are distributed to nodes via install/update scripts",

  "tappaas": {
    "version": "${TAPPAAS_VERSION}",
    "domain": "${DOMAIN}",
    "email": "${EMAIL}",
    "nodeCount": ${NODE_COUNT},
    "upstreamGit": "${UPSTREAM_GIT}",
    "branch": "${BRANCH}",
    "updateSchedule": ${SCHEDULE_JSON}
  },

  "tappaas-nodes": ${NODES_JSON}
}
EOF
)

# Validate the generated JSON
if ! echo "$CONFIG_JSON" | jq '.' >/dev/null 2>&1; then
  die "Generated JSON is invalid. Please check the inputs."
fi

# Pretty-print and save the configuration
echo "$CONFIG_JSON" | jq '.' > "$CONFIG_FILE"

info ""
info "${GN}Configuration saved to:${CL} ${BGN}${CONFIG_FILE}${CL}"
echo ""

# Display summary
echo -e "${BL}=== Configuration Summary ===${CL}"
echo "$CONFIG_JSON" | jq '.'
echo ""
echo -e "${GN}Configuration created successfully!${CL}"
echo ""
echo "Next steps:"
echo "  1. Review the configuration: cat ${CONFIG_FILE}"
echo "  2. The configuration will be distributed to nodes during module installation/update"
