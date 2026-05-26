#!/usr/bin/env bash
#
# Validate configuration.json for correctness and consistency
#
# Usage: validate-configuration.sh [OPTIONS]
#
# Performs sanity checks on /home/tappaas/config/configuration.json including
# field presence, value validity, node uniqueness, and optional connectivity checks.
#
# Exit codes: 0 = all checks pass, 1 = validation errors found
#
set -euo pipefail

# Source common-install-routines.sh if available (provides info, warn, error, die, colors)
if ! declare -F info &>/dev/null; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        . /home/tappaas/bin/common-install-routines.sh
    else
        # Minimal fallback
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

# Check for required commands
command -v jq >/dev/null 2>&1 || die "jq is required but not installed."

# Defaults
CONFIG_FILE="/home/tappaas/config/configuration.json"
CHECK_CONNECTIVITY=false
CHECK_CLUSTER=false
CHECK_REPOS=false
QUIET=false
MGMT="mgmt"

# Error counter
ERRORS=0
WARNINGS=0

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate TAPPaaS configuration.json for correctness and consistency.

Options:
    -h, --help               Show this help message and exit
    --config <path>          Path to configuration.json (default: /home/tappaas/config/configuration.json)
    --check-connectivity     Ping each node IP to verify reachability
    --check-cluster          SSH to first node, verify cluster nodes match configuration
    --check-repos            Verify repository URLs are accessible via git ls-remote
    --quiet                  Only output errors, suppress info messages

Exit Codes:
    0    All checks passed
    1    One or more validation errors found

Examples:
    $(basename "$0")
    $(basename "$0") --check-cluster --check-repos
    $(basename "$0") --config /tmp/test-config.json --quiet
EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --config)
                [[ -n "${2:-}" ]] || die "--config requires a path argument"
                CONFIG_FILE="$2"
                shift 2
                ;;
            --check-connectivity)
                CHECK_CONNECTIVITY=true
                shift
                ;;
            --check-cluster)
                CHECK_CLUSTER=true
                shift
                ;;
            --check-repos)
                CHECK_REPOS=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# Logging wrapper that respects --quiet
log_info() {
    if [[ "$QUIET" == "false" ]]; then
        info "$@"
    fi
}

# Record a validation error
validation_error() {
    error "VALIDATION: $*"
    ERRORS=$((ERRORS + 1))
}

# Record a validation warning
validation_warn() {
    warn "VALIDATION: $*"
    WARNINGS=$((WARNINGS + 1))
}

# --------------------------------------------------------------------------
# Validation checks
# --------------------------------------------------------------------------

# Check that configuration.json exists and is valid JSON
check_file_exists_and_valid() {
    log_info "Checking file existence and JSON validity..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        validation_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        validation_error "Configuration file is not valid JSON: $CONFIG_FILE"
        return 1
    fi

    log_info "  File exists and is valid JSON"
    return 0
}

# Check that all required fields are present
check_required_fields() {
    log_info "Checking required fields..."

    local missing=0

    for field in version domain email nodeCount repositories; do
        if [[ "$(jq -r ".tappaas.${field} // \"__MISSING__\"" "$CONFIG_FILE")" == "__MISSING__" ]]; then
            validation_error "Missing required field: tappaas.${field}"
            missing=$((missing + 1))
        fi
    done

    if [[ "$(jq -r '."tappaas-nodes" // "__MISSING__"' "$CONFIG_FILE")" == "__MISSING__" ]]; then
        validation_error "Missing required section: tappaas-nodes"
        missing=$((missing + 1))
    fi

    if [[ $missing -eq 0 ]]; then
        log_info "  All required fields present"
    fi
}

# Check that domain and email don't start with CHANGE
check_must_change_fields() {
    log_info "Checking must-change fields..."

    local domain
    local email
    domain=$(jq -r '.tappaas.domain // ""' "$CONFIG_FILE")
    email=$(jq -r '.tappaas.email // ""' "$CONFIG_FILE")

    # Placeholder domain/email are WARNINGS, not errors: the automated install
    # intentionally starts with a placeholder domain and sets the real one later
    # (create-configuration.sh --update --domain ...). The platform installs fine
    # with the placeholder; only public TLS for app services needs a real domain.
    if [[ "$domain" == CHANGE* ]]; then
        validation_warn "tappaas.domain still has the placeholder '$domain' — set it before installing public services (create-configuration.sh --update --domain <yourdomain>)"
    fi

    if [[ "$email" == CHANGE* ]]; then
        validation_warn "tappaas.email still has the placeholder '$email' — set it before TLS issuance (create-configuration.sh --update --email <you@domain>)"
    fi

    # Basic email format validation
    if [[ -n "$email" && "$email" != CHANGE* ]]; then
        if ! [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            validation_warn "tappaas.email may not be a valid email format: '$email'"
        fi
    fi
}

# Check that nodeCount matches the tappaas-nodes array length
check_node_count() {
    log_info "Checking node count consistency..."

    local declared_count
    local actual_count
    declared_count=$(jq -r '.tappaas.nodeCount // 0' "$CONFIG_FILE")
    actual_count=$(jq -r '."tappaas-nodes" | length' "$CONFIG_FILE")

    if [[ "$declared_count" -ne "$actual_count" ]]; then
        validation_error "tappaas.nodeCount ($declared_count) does not match tappaas-nodes array length ($actual_count)"
    else
        log_info "  nodeCount ($declared_count) matches tappaas-nodes array length"
    fi
}

# Check for duplicate IPs and hostnames
check_unique_nodes() {
    log_info "Checking for duplicate IPs and hostnames..."

    local dup_ips
    local dup_hostnames

    dup_ips=$(jq -r '."tappaas-nodes"[].ip' "$CONFIG_FILE" | sort | uniq -d)
    if [[ -n "$dup_ips" ]]; then
        validation_error "Duplicate IPs found in tappaas-nodes: $dup_ips"
    fi

    dup_hostnames=$(jq -r '."tappaas-nodes"[].hostname' "$CONFIG_FILE" | sort | uniq -d)
    if [[ -n "$dup_hostnames" ]]; then
        validation_error "Duplicate hostnames found in tappaas-nodes: $dup_hostnames"
    fi

    if [[ -z "$dup_ips" && -z "$dup_hostnames" ]]; then
        log_info "  All node IPs and hostnames are unique"
    fi
}

# Validate updateSchedule values
check_update_schedule() {
    log_info "Checking updateSchedule..."

    local schedule_length
    schedule_length=$(jq -r '.tappaas.updateSchedule | length // 0' "$CONFIG_FILE")

    if [[ "$schedule_length" -eq 0 ]]; then
        log_info "  No updateSchedule configured (optional field)"
        return
    fi

    local frequency
    local weekday
    local hour
    frequency=$(jq -r '.tappaas.updateSchedule[0] // ""' "$CONFIG_FILE")
    weekday=$(jq -r '.tappaas.updateSchedule[1] // "null"' "$CONFIG_FILE")
    hour=$(jq -r '.tappaas.updateSchedule[2] // ""' "$CONFIG_FILE")

    case "$frequency" in
        none|daily|weekly|monthly) ;;
        *)
            validation_error "Invalid updateSchedule frequency: '$frequency'. Must be one of: none, daily, weekly, monthly"
            ;;
    esac

    if [[ "$frequency" != "daily" && "$weekday" != "null" ]]; then
        case "$weekday" in
            Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) ;;
            *)
                validation_error "Invalid updateSchedule weekday: '$weekday'. Must be a valid day name"
                ;;
        esac
    fi

    if [[ -n "$hour" && "$hour" != "null" ]]; then
        if ! [[ "$hour" =~ ^[0-9]+$ ]] || [[ "$hour" -lt 0 ]] || [[ "$hour" -gt 23 ]]; then
            validation_error "Invalid updateSchedule hour: '$hour'. Must be 0-23"
        fi
    fi

    if [[ $ERRORS -eq 0 ]]; then
        log_info "  updateSchedule is valid: [$frequency, $weekday, $hour]"
    fi
}

# Validate dns-hostname fields if present
check_dns_hostnames() {
    log_info "Checking dns-hostname fields..."

    local node_count
    node_count=$(jq -r '."tappaas-nodes" | length' "$CONFIG_FILE")

    for ((i = 0; i < node_count; i++)); do
        local dns_hostname
        dns_hostname=$(jq -r ".[\"tappaas-nodes\"][$i].\"dns-hostname\" // \"__NOTSET__\"" "$CONFIG_FILE")

        if [[ "$dns_hostname" != "__NOTSET__" ]]; then
            if [[ -z "$dns_hostname" ]]; then
                local hostname
                hostname=$(jq -r ".[\"tappaas-nodes\"][$i].hostname" "$CONFIG_FILE")
                validation_error "tappaas-nodes[$i] ($hostname): dns-hostname is set but empty"
            else
                log_info "  Node $i: dns-hostname='$dns_hostname'"
            fi
        fi
    done
}

# Validate node IPs are proper IPv4 format
check_ip_format() {
    log_info "Checking IP address format..."

    local node_count
    node_count=$(jq -r '."tappaas-nodes" | length' "$CONFIG_FILE")

    for ((i = 0; i < node_count; i++)); do
        local ip
        local hostname
        ip=$(jq -r ".[\"tappaas-nodes\"][$i].ip" "$CONFIG_FILE")
        hostname=$(jq -r ".[\"tappaas-nodes\"][$i].hostname" "$CONFIG_FILE")

        if [[ "$ip" == "unknown" ]]; then
            validation_warn "tappaas-nodes[$i] ($hostname): IP is 'unknown' — node discovery may have failed"
        elif ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            validation_error "tappaas-nodes[$i] ($hostname): Invalid IP format: '$ip'"
        fi
    done
}

# Optional: check node connectivity
check_connectivity() {
    log_info "Checking node connectivity (ping)..."

    local node_count
    node_count=$(jq -r '."tappaas-nodes" | length' "$CONFIG_FILE")

    for ((i = 0; i < node_count; i++)); do
        local ip
        local hostname
        ip=$(jq -r ".[\"tappaas-nodes\"][$i].ip" "$CONFIG_FILE")
        hostname=$(jq -r ".[\"tappaas-nodes\"][$i].hostname" "$CONFIG_FILE")

        if [[ "$ip" == "unknown" ]]; then
            validation_warn "Skipping connectivity check for $hostname (IP unknown)"
            continue
        fi

        if ping -c 1 -W 3 "$ip" >/dev/null 2>&1; then
            log_info "  $hostname ($ip): reachable"
        else
            validation_warn "$hostname ($ip): not reachable via ping"
        fi
    done
}

# Optional: check cluster nodes match configuration
check_cluster() {
    log_info "Checking cluster nodes match configuration..."

    # Determine primary node FQDN from configuration
    local primary_dns
    primary_dns=$(jq -r '."tappaas-nodes"[0]."dns-hostname" // ."tappaas-nodes"[0].hostname // "tappaas1"' "$CONFIG_FILE")
    local primary_fqdn="${primary_dns}.${MGMT}.internal"

    log_info "  Connecting to primary node: $primary_fqdn"

    local cluster_nodes
    cluster_nodes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${primary_fqdn}" \
        "pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[].node'" 2>/dev/null || true)

    if [[ -z "$cluster_nodes" ]]; then
        validation_warn "Could not retrieve cluster node list from $primary_fqdn"
        return
    fi

    # Check that all cluster nodes are in configuration
    local config_hostnames
    config_hostnames=$(jq -r '."tappaas-nodes"[].hostname' "$CONFIG_FILE")

    while IFS= read -r cluster_node; do
        if ! echo "$config_hostnames" | grep -qx "$cluster_node"; then
            validation_warn "Cluster node '$cluster_node' is not in configuration.json"
        fi
    done <<< "$cluster_nodes"

    # Check that all configured nodes are in the cluster
    while IFS= read -r config_node; do
        if ! echo "$cluster_nodes" | grep -qx "$config_node"; then
            validation_warn "Configured node '$config_node' is not found in the Proxmox cluster"
        fi
    done <<< "$config_hostnames"

    log_info "  Cluster check complete"
}

# Optional: check repository accessibility
check_repos() {
    log_info "Checking repository accessibility..."

    local repo_count
    repo_count=$(jq -r '.tappaas.repositories | length' "$CONFIG_FILE")

    for ((i = 0; i < repo_count; i++)); do
        local url
        local name
        url=$(jq -r ".tappaas.repositories[$i].url" "$CONFIG_FILE")
        name=$(jq -r ".tappaas.repositories[$i].name" "$CONFIG_FILE")

        if git ls-remote "https://${url}" HEAD >/dev/null 2>&1; then
            log_info "  $name (https://$url): accessible"
        else
            validation_warn "$name (https://$url): not accessible via git ls-remote"
        fi
    done
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    parse_args "$@"

    log_info "Validating configuration: $CONFIG_FILE"
    echo ""

    # Core checks — abort early if file is missing or invalid JSON
    if ! check_file_exists_and_valid; then
        echo ""
        error "Validation failed: $ERRORS error(s)"
        exit 1
    fi

    check_required_fields
    check_must_change_fields
    check_node_count
    check_unique_nodes
    check_update_schedule
    check_dns_hostnames
    check_ip_format

    # Optional checks
    if [[ "$CHECK_CONNECTIVITY" == "true" ]]; then
        check_connectivity
    fi

    if [[ "$CHECK_CLUSTER" == "true" ]]; then
        check_cluster
    fi

    if [[ "$CHECK_REPOS" == "true" ]]; then
        check_repos
    fi

    # Summary
    echo ""
    if [[ $ERRORS -gt 0 ]]; then
        error "Validation failed: $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warn "Validation passed with $WARNINGS warning(s)"
        exit 0
    else
        log_info "${GN}Validation passed: all checks OK${CL}"
        exit 0
    fi
}

main "$@"
