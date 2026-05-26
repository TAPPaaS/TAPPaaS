#!/usr/bin/env bash
#
# Create or update configuration.json for the current running TAPPaaS system
#
# Supports two argument styles:
#   Positional (backwards compatible):
#     create-configuration.sh <upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]
#
#   Named arguments with defaults:
#     create-configuration.sh [--upstream-git URL] [--branch NAME] [--domain DOMAIN]
#                             [--email EMAIL] [--schedule FREQ] [--weekday DAY] [--hour H]
#                             [--primary-node FQDN] [--update]
#
# When --update is used and configuration.json already exists, existing values are
# used as defaults and only provided arguments are overwritten. Cluster nodes are
# re-discovered from the running Proxmox cluster.
#
# When no arguments are provided (named-arg mode with all defaults), the script uses
# sensible defaults and reads existing values from configuration.json if present.
#
set -euo pipefail

# Source common-install-routines.sh if not already loaded (provides info, warn, error, die, colors)
if ! declare -F info &>/dev/null; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        . /home/tappaas/bin/common-install-routines.sh
    else
        # Minimal fallback for bootstrap before common-install-routines.sh exists
        : "${YW:=$'\033[33m'}"
        : "${BL:=$'\033[36m'}"
        : "${RD:=$'\033[01;31m'}"
        : "${BGN:=$'\033[4;92m'}"
        : "${GN:=$'\033[1;92m'}"
        : "${DGN:=$'\033[32m'}"
        : "${CL:=$'\033[m'}"
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        debug() { :; }  # no-op unless TAPPAAS_DEBUG is set
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$*"; exit 1; }
    fi
fi

# Check for required commands
command -v jq >/dev/null 2>&1 || die "jq is required but not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is required but not installed."

# Configuration file paths
CONFIG_DIR="/home/tappaas/config"
CONFIG_FILE="${CONFIG_DIR}/configuration.json"
MGMT="mgmt"

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]
       $(basename "$0") <upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]

Create or update TAPPaaS configuration.json by discovering the running cluster.

Named Arguments (all optional, defaults apply):
    --upstream-git URL    Git repository URL (default: github.com/TAPPaaS/TAPPaaS)
    --branch NAME         Git branch to track (default: stable)
    --domain DOMAIN       Primary domain for TAPPaaS (default: from existing config or CHANGE-domain.tld)
    --email EMAIL         Admin email address (default: from Proxmox root@pam user or existing config)
    --schedule FREQ       Update frequency: monthly, weekly, daily, none (default: weekly)
    --weekday DAY         Day of week for updates (default: Tuesday)
    --hour H              Hour of day 0-23 for updates (default: 2)
    --primary-node FQDN   Primary node FQDN for cluster discovery (default: auto-detect from config)
    --update              Update mode: preserve existing config values, overlay provided args
    -h, --help            Show this help message

Positional Arguments (backwards compatible):
    upstreamGit branch domain email schedule [weekday] [hour]

Defaults:
    When called with no arguments or in named-arg mode, defaults are used for any
    unspecified values. If configuration.json already exists, its values serve as
    defaults (in --update mode, this is automatic for all fields).

Examples:
    $(basename "$0")                                                    # All defaults
    $(basename "$0") --update --domain newdomain.com                    # Update only domain
    $(basename "$0") --domain my.dev --email admin@my.dev               # Create with specific domain/email
    $(basename "$0") github.com/TAPPaaS/TAPPaaS main my.dev a@my.dev weekly   # Positional (legacy)
EOF
}

# --------------------------------------------------------------------------
# Read existing configuration values (if file exists)
# --------------------------------------------------------------------------
read_existing_config() {
    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        EXISTING_UPSTREAM_GIT=$(jq -r '.tappaas.repositories[0].url // ""' "$CONFIG_FILE")
        EXISTING_BRANCH=$(jq -r '.tappaas.repositories[0].branch // ""' "$CONFIG_FILE")
        EXISTING_DOMAIN=$(jq -r '.tappaas.domain // ""' "$CONFIG_FILE")
        EXISTING_EMAIL=$(jq -r '.tappaas.email // ""' "$CONFIG_FILE")
        EXISTING_SCHEDULE=$(jq -r '.tappaas.updateSchedule[0] // ""' "$CONFIG_FILE")
        EXISTING_WEEKDAY=$(jq -r '.tappaas.updateSchedule[1] // ""' "$CONFIG_FILE")
        EXISTING_HOUR=$(jq -r '.tappaas.updateSchedule[2] // ""' "$CONFIG_FILE")
        EXISTING_PRIMARY_DNS=$(jq -r '."tappaas-nodes"[0]."dns-hostname" // ."tappaas-nodes"[0].hostname // ""' "$CONFIG_FILE")
        EXISTING_REPOS=$(jq -c '.tappaas.repositories // []' "$CONFIG_FILE")
        # Preserve existing dns-hostname mappings
        EXISTING_DNS_MAP=$(jq -c '[."tappaas-nodes"[] | {(.hostname): (."dns-hostname" // null)}] | add // {}' "$CONFIG_FILE")
        return 0
    fi
    return 1
}

# --------------------------------------------------------------------------
# Discover domain and email from the Proxmox node's installer settings
# --------------------------------------------------------------------------
discover_node_defaults() {
    local primary_node="${1:-tappaas1.${MGMT}.internal}"

    # Note: domain is NOT discovered from the node — the Proxmox FQDN uses the
    # internal management domain (e.g., mgmt.internal), not the public domain.
    # The user must provide the public domain explicitly or update the CHANGE- placeholder.

    # Try to get the admin email from /etc/pve/user.cfg (root@pam entry)
    # Format: user:root@pam:1:0:::email@domain.com:::
    local user_cfg
    user_cfg=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
        "grep '^user:root@pam:' /etc/pve/user.cfg 2>/dev/null" 2>/dev/null || true)

    if [[ -n "$user_cfg" ]]; then
        # Field 7 (0-indexed 6) is the email — split by colon
        local pve_email
        pve_email=$(echo "$user_cfg" | cut -d: -f7)
        if [[ -n "$pve_email" && "$pve_email" == *@* ]]; then
            DISCOVERED_EMAIL="$pve_email"
            debug "  Discovered email from Proxmox user.cfg: ${DISCOVERED_EMAIL}"
        fi
    fi
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
parse_args() {
    UPDATE_MODE=false
    PRIMARY_NODE_OVERRIDE=""

    # Detect argument style: if $1 starts with -- or no args, use named-arg mode
    if [[ $# -eq 0 ]] || [[ "${1:-}" == --* ]] || [[ "${1:-}" == -h ]]; then
        # Named argument mode — start with defaults
        UPSTREAM_GIT="github.com/TAPPaaS/TAPPaaS"
        BRANCH="stable"
        DOMAIN="CHANGE-domain.tld"
        EMAIL="${DISCOVERED_EMAIL:-CHANGE-admin@domain.tld}"
        UPDATE_SCHEDULE="weekly"
        UPDATE_WEEKDAY="Tuesday"
        UPDATE_HOUR="2"

        # Track which arguments were explicitly provided on the command line
        local _set_upstream=false _set_branch=false _set_domain=false _set_email=false
        local _set_schedule=false _set_weekday=false _set_hour=false

        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--help)
                    usage
                    exit 0
                    ;;
                --upstream-git)
                    [[ -n "${2:-}" ]] || die "--upstream-git requires a value"
                    UPSTREAM_GIT="$2"; _set_upstream=true; shift 2
                    ;;
                --branch)
                    [[ -n "${2:-}" ]] || die "--branch requires a value"
                    BRANCH="$2"; _set_branch=true; shift 2
                    ;;
                --domain)
                    [[ -n "${2:-}" ]] || die "--domain requires a value"
                    DOMAIN="$2"; _set_domain=true; shift 2
                    ;;
                --email)
                    [[ -n "${2:-}" ]] || die "--email requires a value"
                    EMAIL="$2"; _set_email=true; shift 2
                    ;;
                --schedule)
                    [[ -n "${2:-}" ]] || die "--schedule requires a value"
                    UPDATE_SCHEDULE="$2"; _set_schedule=true; shift 2
                    ;;
                --weekday)
                    [[ -n "${2:-}" ]] || die "--weekday requires a value"
                    UPDATE_WEEKDAY="$2"; _set_weekday=true; shift 2
                    ;;
                --hour)
                    [[ -n "${2:-}" ]] || die "--hour requires a value"
                    UPDATE_HOUR="$2"; _set_hour=true; shift 2
                    ;;
                --primary-node)
                    [[ -n "${2:-}" ]] || die "--primary-node requires a value"
                    PRIMARY_NODE_OVERRIDE="$2"; shift 2
                    ;;
                --update)
                    UPDATE_MODE=true; shift
                    ;;
                *)
                    die "Unknown option: $1. Use --help for usage."
                    ;;
            esac
        done

        # Read existing config (needed for dns-hostname preservation in all modes)
        read_existing_config || true

        # Preserve existing config values for fields not explicitly provided
        # WHENEVER a configuration already exists — not only in explicit --update
        # mode. This makes create-configuration idempotent: re-running it (e.g.
        # install2 on a platform re-run, which sources this without --update) keeps
        # the already-set domain/branch/email/etc. instead of resetting them to the
        # defaults (which would clobber the real domain with CHANGE-domain.tld).
        # Explicitly-passed flags still override.
        if [[ -n "${EXISTING_DOMAIN:-}" ]]; then
            info "Existing configuration found — preserving values not explicitly overridden..."
            [[ "$_set_upstream" == "true" ]] || UPSTREAM_GIT="${EXISTING_UPSTREAM_GIT:-$UPSTREAM_GIT}"
            [[ "$_set_branch" == "true" ]]   || BRANCH="${EXISTING_BRANCH:-$BRANCH}"
            [[ "$_set_domain" == "true" ]]   || DOMAIN="${EXISTING_DOMAIN:-$DOMAIN}"
            [[ "$_set_email" == "true" ]]    || EMAIL="${EXISTING_EMAIL:-$EMAIL}"
            [[ "$_set_schedule" == "true" ]] || UPDATE_SCHEDULE="${EXISTING_SCHEDULE:-$UPDATE_SCHEDULE}"
            [[ "$_set_weekday" == "true" ]]  || UPDATE_WEEKDAY="${EXISTING_WEEKDAY:-$UPDATE_WEEKDAY}"
            [[ "$_set_hour" == "true" ]]     || UPDATE_HOUR="${EXISTING_HOUR:-$UPDATE_HOUR}"
        elif [[ "$UPDATE_MODE" == "true" ]]; then
            warn "Update mode requested but no existing configuration.json found. Creating new configuration."
        fi
    else
        # Positional argument mode (backwards compatible)
        if [[ $# -lt 5 ]]; then
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

        # Still read existing config for dns-hostname preservation
        read_existing_config || true
    fi
}

# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
validate_inputs() {
    # Validate updateSchedule
    case "$UPDATE_SCHEDULE" in
        monthly|weekly|daily|none) ;;
        *)
            die "Invalid updateSchedule: '$UPDATE_SCHEDULE'. Must be one of: monthly, weekly, daily, none"
            ;;
    esac

    # Validate weekday
    case "$UPDATE_WEEKDAY" in
        Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) ;;
        null) ;;  # valid for daily schedule
        *)
            die "Invalid weekday: '$UPDATE_WEEKDAY'. Must be one of: Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday"
            ;;
    esac

    # Validate hour
    if ! [[ "$UPDATE_HOUR" =~ ^[0-9]+$ ]] || [[ "$UPDATE_HOUR" -lt 0 ]] || [[ "$UPDATE_HOUR" -gt 23 ]]; then
        die "Invalid hour: '$UPDATE_HOUR'. Must be an integer between 0 and 23"
    fi

    # Validate email format (basic check, warn only)
    if [[ "$EMAIL" != CHANGE* ]] && ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        warn "Email '$EMAIL' may not be in a valid format."
    fi
}

# --------------------------------------------------------------------------
# Cluster discovery
# --------------------------------------------------------------------------
discover_cluster_nodes() {
    info "Discovering Proxmox cluster nodes..."

    NODES=()
    NODE_IPS=()

    # Determine primary node FQDN for cluster discovery
    local primary_node
    if [[ -n "$PRIMARY_NODE_OVERRIDE" ]]; then
        primary_node="$PRIMARY_NODE_OVERRIDE"
    elif [[ -n "${EXISTING_PRIMARY_DNS:-}" ]]; then
        primary_node="${EXISTING_PRIMARY_DNS}.${MGMT}.internal"
    else
        # Bootstrap default — first install assumes tappaas1
        primary_node="tappaas1.${MGMT}.internal"
    fi

    debug "  Primary node for discovery: ${BGN}${primary_node}${CL}"

    # Get list of cluster nodes via pvesh JSON API (most reliable method)
    local cluster_nodes=""
    debug "  Trying pvesh JSON API to list nodes..."
    cluster_nodes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
        "pvesh get /cluster/status --output-format=json 2>/dev/null | jq -r '[.[] | select(.type==\"node\")] | sort_by(.nodeid) | .[].name' | grep -v '^null$'" 2>/dev/null || true)

    # Fallback: try pvecm nodes (text parsing)
    # Note: pvecm output varies — with Qdevice the Name column shifts, and the
    # local node is shown as "name (local)". We use awk to grab the Name column
    # by finding its position from the header, which handles both layouts.
    if [[ -z "$cluster_nodes" ]]; then
        debug "  Falling back to pvecm nodes..."
        cluster_nodes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
            "pvecm nodes 2>/dev/null" 2>/dev/null | awk '
                /Name/ { for (i=1; i<=NF; i++) if ($i == "Name") name_col=i; next }
                /^[[:space:]]*[0-9]/ && name_col { print $name_col }
            ' | sed 's/ *(local)$//' || true)
    fi

    # If still empty, extract hostname from the primary FQDN
    if [[ -z "$cluster_nodes" ]]; then
        local fallback_hostname
        fallback_hostname="${primary_node%%.*}"
        warn "Could not discover cluster nodes. Using '${fallback_hostname}' as default."
        cluster_nodes="$fallback_hostname"
    fi

    info "  Found nodes: ${cluster_nodes}"

    # Get IP addresses for each node
    for node in $cluster_nodes; do
        # Validate node name looks like a hostname (alphanumeric + hyphens)
        if [[ ! "$node" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            warn "Skipping invalid node name: '$node'"
            continue
        fi
        NODES+=("$node")

        local node_ip=""
        # Determine FQDN: use dns-hostname from existing config if available, else use node name
        local node_dns="$node"
        if [[ -n "${EXISTING_DNS_MAP:-}" ]]; then
            local mapped_dns
            mapped_dns=$(echo "$EXISTING_DNS_MAP" | jq -r ".\"${node}\" // empty" 2>/dev/null || true)
            if [[ -n "$mapped_dns" && "$mapped_dns" != "null" ]]; then
                node_dns="$mapped_dns"
            fi
        fi
        local node_fqdn="${node_dns}.${MGMT}.internal"

        # Method 1: DNS lookup
        node_ip=$(getent hosts "$node_fqdn" 2>/dev/null | awk '{print $1}' | head -1 || true)

        # Method 2: Query the node directly
        if [[ -z "$node_ip" ]]; then
            node_ip=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${node_fqdn}" \
                "ip -4 addr show | grep -oP '(?<=inet\\s)[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+(?=/)' | grep -Ev '^(127\\.|169\\.254\\.)' | head -1" 2>/dev/null || true)
        fi

        if [[ -z "$node_ip" ]]; then
            warn "Could not determine IP for node $node"
            node_ip="unknown"
        fi

        NODE_IPS+=("$node_ip")
        debug "  ${node}: ${node_ip}"
    done

    NODE_COUNT=${#NODES[@]}
    info "  Total nodes: ${NODE_COUNT}"
}

# --------------------------------------------------------------------------
# Build and write configuration JSON
# --------------------------------------------------------------------------
build_and_write_config() {
    info "Generating configuration.json..."

    # Get TAPPaaS version from git
    local tappaas_version="0.5"
    if [[ -f "/home/tappaas/TAPPaaS/.git/HEAD" ]]; then
        pushd /home/tappaas/TAPPaaS >/dev/null
        tappaas_version=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.5")
        popd >/dev/null
    fi
    debug "TAPPaaS Version: ${BGN}${tappaas_version}${CL}"

    # Build the tappaas-nodes array
    debug "Building node configuration..."
    local nodes_json="["
    local first_node=true

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local ip="${NODE_IPS[$i]}"

        if [[ "$first_node" == "true" ]]; then
            first_node=false
        else
            nodes_json+=","
        fi

        # Check if this node has a dns-hostname from existing config
        local dns_hostname_entry=""
        if [[ -n "${EXISTING_DNS_MAP:-}" ]]; then
            local dns_val
            dns_val=$(echo "$EXISTING_DNS_MAP" | jq -r ".\"${node}\" // empty" 2>/dev/null || true)
            if [[ -n "$dns_val" && "$dns_val" != "null" ]]; then
                dns_hostname_entry="\"dns-hostname\": \"${dns_val}\","
            fi
        fi

        if [[ -n "$dns_hostname_entry" ]]; then
            nodes_json+=$(printf '\n    {\n      "hostname": "%s",\n      %s\n      "ip": "%s"\n    }' "$node" "$dns_hostname_entry" "$ip")
        else
            nodes_json+=$(printf '\n    {\n      "hostname": "%s",\n      "ip": "%s"\n    }' "$node" "$ip")
        fi
    done

    nodes_json+="]"

    # Build the updateSchedule
    local schedule_json
    if [[ "$UPDATE_SCHEDULE" == "daily" ]]; then
        schedule_json="[\"daily\", null, ${UPDATE_HOUR}]"
    elif [[ "$UPDATE_SCHEDULE" == "none" ]]; then
        schedule_json="[\"none\", null, null]"
    else
        schedule_json="[\"${UPDATE_SCHEDULE}\", \"${UPDATE_WEEKDAY}\", ${UPDATE_HOUR}]"
    fi
    debug "Global updateSchedule: ${schedule_json}"

    # Build repositories array: in update mode preserve existing repos, otherwise create default
    local repos_json
    if [[ "$UPDATE_MODE" == "true" && -n "${EXISTING_REPOS:-}" && "$EXISTING_REPOS" != "[]" ]]; then
        # Update the first repo's URL and branch, preserve the rest
        repos_json=$(echo "$EXISTING_REPOS" | jq --arg url "$UPSTREAM_GIT" --arg branch "$BRANCH" \
            '.[0].url = $url | .[0].branch = $branch')
    else
        repos_json=$(printf '[{"name": "TAPPaaS", "url": "%s", "branch": "%s", "path": "/home/tappaas/TAPPaaS"}]' "$UPSTREAM_GIT" "$BRANCH")
    fi

    # Build the complete configuration JSON
    local config_json
    config_json=$(cat << CONFIGEOF
{
  "-comment1": "TAPPaaS Configuration - Generated $(date '+%Y-%m-%d %H:%M:%S')",
  "-comment2": "Edit this file at ${CONFIG_FILE}",

  "tappaas": {
    "version": "${tappaas_version}",
    "domain": "${DOMAIN}",
    "email": "${EMAIL}",
    "nodeCount": ${NODE_COUNT},
    "repositories": ${repos_json},
    "updateSchedule": ${schedule_json}
  },

  "tappaas-nodes": ${nodes_json}
}
CONFIGEOF
)

    # Validate the generated JSON
    if ! echo "$config_json" | jq '.' >/dev/null 2>&1; then
        die "Generated JSON is invalid. Please check the inputs."
    fi

    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"

    # Pretty-print and save the configuration
    echo "$config_json" | jq '.' > "$CONFIG_FILE"

    echo ""
    info "${GN}Configuration saved to:${CL} ${BGN}${CONFIG_FILE}${CL}"

    # Display summary
    info "Configuration Summary:"
    debug "$(echo "$config_json" | jq '.')"
}

# --------------------------------------------------------------------------
# Post-write validation
# --------------------------------------------------------------------------
run_validation() {
    local validator="/home/tappaas/bin/validate-configuration.sh"
    if [[ -x "$validator" ]]; then
        info "Running configuration validation..."
        "$validator" --config "$CONFIG_FILE" --quiet || {
            warn "Configuration validation reported issues. Review with: validate-configuration.sh --config $CONFIG_FILE"
        }
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    # Initialize existing config variables
    EXISTING_UPSTREAM_GIT=""
    EXISTING_BRANCH=""
    EXISTING_DOMAIN=""
    EXISTING_EMAIL=""
    EXISTING_SCHEDULE=""
    EXISTING_WEEKDAY=""
    EXISTING_HOUR=""
    EXISTING_PRIMARY_DNS=""
    EXISTING_REPOS=""
    EXISTING_DNS_MAP=""

    # Initialize discovered defaults (from Proxmox node)
    DISCOVERED_EMAIL=""

    # Discover domain/email from the primary Proxmox node's installer settings.
    # This runs before parse_args so discovered values can serve as defaults.
    # Determine which node to query: check --primary-node in args, else existing config, else tappaas1
    local discovery_node="tappaas1.${MGMT}.internal"
    # Quick scan for --primary-node in args
    local i _prev_was_primary=false
    for i in "$@"; do
        if [[ "$_prev_was_primary" == "true" ]]; then
            discovery_node="$i"
            break
        fi
        [[ "$i" == "--primary-node" ]] && _prev_was_primary=true || _prev_was_primary=false
    done
    # Also try existing config if available
    if [[ "$discovery_node" == "tappaas1.${MGMT}.internal" && -f "$CONFIG_FILE" ]]; then
        local existing_dns
        existing_dns=$(jq -r '."tappaas-nodes"[0]."dns-hostname" // ."tappaas-nodes"[0].hostname // ""' "$CONFIG_FILE" 2>/dev/null || true)
        [[ -n "$existing_dns" ]] && discovery_node="${existing_dns}.${MGMT}.internal"
    fi
    info "Discovering defaults from Proxmox node: ${discovery_node}..."
    discover_node_defaults "$discovery_node"

    parse_args "$@"
    validate_inputs

    if [[ "$UPDATE_MODE" == "true" ]]; then
        info "Updating TAPPaaS configuration..."
    else
        info "Creating TAPPaaS configuration..."
    fi

    debug "  Upstream Git: ${BGN}${UPSTREAM_GIT}${CL}"
    debug "  Branch: ${BGN}${BRANCH}${CL}"
    debug "  Domain: ${BGN}${DOMAIN}${CL}"
    debug "  Email: ${BGN}${EMAIL}${CL}"
    debug "  Update Schedule: ${BGN}${UPDATE_SCHEDULE}, ${UPDATE_WEEKDAY}, hour ${UPDATE_HOUR}${CL}"

    discover_cluster_nodes
    build_and_write_config
    run_validation

    echo ""
    info "${GN}✓${CL} Configuration ${UPDATE_MODE:+updated}${UPDATE_MODE:+}${UPDATE_MODE:-created} successfully"
    info "Next steps:"
    info "  1. Review the configuration: cat ${CONFIG_FILE}"
    info "  2. Validate: validate-configuration.sh"
}

main "$@"
