#!/usr/bin/env bash
#
# create-site.sh — site-native installer-config creator (ADR-007 P2 / S3b+).
#
# Discovers the running Proxmox cluster and writes config/site.json DIRECTLY —
# it NEVER reads or writes configuration.json. This is the fresh-install
# replacement for create-configuration.sh: where that script discovers the
# cluster and emits the legacy configuration.json, this one emits the
# site-native site.json (ADR-007d), so configuration.json can eventually be
# retired from the fresh-install flow.
#
# Field mapping (CLI/discovery -> site.json), matching site-fields.json and the
# migrate-configuration.sh target shape:
#   name              <- --name (REQUIRED)               [schema: name]
#   displayName       <- --name                          [schema: displayName]
#   owner             <- --name (single owner org keyed on the site name; an org
#                        file may be created later by people-manager)  [schema: owner]
#   email             <- --email / Proxmox root@pam user / existing  [schema: email]
#   version           <- git describe of /home/tappaas/TAPPaaS, else "1.0"
#   location.country  <- derived from system timezone region (fallback NL)
#   location.timezone <- system tz (timedatectl/zoneinfo, fallback Europe/Amsterdam)
#   location.locale   <- system locale ($LANG/localectl, fallback en_US)
#   network.isp       <- null
#   network.publicIp  <- "auto"
#   hardware.nodes[]  <- discovered cluster nodes; each {name, storagePools:[...]}
#                        where storagePools = the tankXY zpools present on that node
#   backup            <- null
#   updateSchedule    <- [--schedule, --weekday, --hour]
#   automaticReboot   <- preserved from existing site.json, else true
#   snapshotRetention <- preserved from existing site.json, else 5
#   repositories[]    <- built from --upstream-git/--branch (default TAPPaaS repo),
#                        preserving any existing operator-set repositories
#   environments      <- []  (create-minimal-environments populates this later)
#   organizations     <- []  (people-manager populates this later)
#
# NOTE on --domain: the PUBLIC domain is per-ENVIRONMENT in the ADR-007 model and
# is NOT a site.json field. --domain is accepted (for parity with
# create-configuration.sh and for the parent installer to forward to
# create-minimal-environments) but it is intentionally NOT written to site.json.
#
# Idempotent: if site.json already exists, --force is required to overwrite. On a
# --force re-run, operator-set fields are preserved (repositories, email,
# automaticReboot, snapshotRetention, owner, displayName, location, network,
# backup) — only discovery-derived and explicitly-passed fields are refreshed.
#
# Usage: create-site.sh --name <N> [OPTIONS]
#
# Options:
#   --name N             REQUIRED. TAPPaaS system name -> site.json .name
#                        (also the default zone / default environment name).
#   --domain DOMAIN      Public domain (NOT written to site.json; per-environment).
#   --branch NAME        Git branch to track (default: stable).
#   --upstream-git URL   Module-catalog git repo (default: github.com/TAPPaaS/TAPPaaS).
#   --email EMAIL        Installer/admin email (default: Proxmox root@pam / existing).
#   --primary-node FQDN  Primary node FQDN for cluster discovery (default: tappaas1).
#   --schedule FREQ      Update frequency: monthly|weekly|daily|none (default: weekly).
#   --weekday DAY        Weekday for updates (default: Tuesday).
#   --hour H             Hour of day 0-23 (default: 2).
#   --config-dir DIR     Config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config}).
#   --force              Overwrite an existing site.json.
#   -h, --help           Show this help and exit.
#
# Exit codes: 0 = success; 1 = error / validation failure.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse common-install-routines.sh when present
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        # shellcheck source=/dev/null
        . /home/tappaas/bin/common-install-routines.sh
    else
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

command -v jq  >/dev/null 2>&1 || die "jq is required but not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is required but not installed."

# ---------------------------------------------------------------------------
# Locate self + schema (create-site.sh is symlinked into /home/tappaas/bin).
# ---------------------------------------------------------------------------
_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${_SELF}")" && pwd)"
# manager/site-manager -> manager -> tappaas-cicd -> foundation
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${SCHEMA_DIR:-${FOUNDATION_DIR}/schemas}"
VALIDATE_SITE="${HERE}/validate-site.sh"

MGMT="mgmt"

# Defaults (overridable by flags)
CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
NAME=""
DOMAIN=""            # accepted, NOT written to site.json (per-environment)
BRANCH="stable"
UPSTREAM_GIT="github.com/TAPPaaS/TAPPaaS"
EMAIL=""
PRIMARY_NODE_OVERRIDE=""
UPDATE_SCHEDULE="weekly"
UPDATE_WEEKDAY="Tuesday"
UPDATE_HOUR="2"
FORCE=false

# Track explicitly-set flags (so existing values are preserved otherwise)
_set_branch=false _set_upstream=false _set_email=false
_set_schedule=false _set_weekday=false _set_hour=false

usage() {
    sed -n '2,62p' "$_SELF" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Cleanup trap — remove any tmp file we created
# ---------------------------------------------------------------------------
TMP_SITE=""
cleanup() {
    [[ -n "${TMP_SITE:-}" && -f "${TMP_SITE}" ]] && rm -f -- "${TMP_SITE}"
    return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --name)
                [[ -n "${2:-}" ]] || die "--name requires a value"
                NAME="$2"; shift 2 ;;
            --domain)
                [[ -n "${2:-}" ]] || die "--domain requires a value"
                DOMAIN="$2"; shift 2 ;;
            --branch)
                [[ -n "${2:-}" ]] || die "--branch requires a value"
                BRANCH="$2"; _set_branch=true; shift 2 ;;
            --upstream-git)
                [[ -n "${2:-}" ]] || die "--upstream-git requires a value"
                UPSTREAM_GIT="$2"; _set_upstream=true; shift 2 ;;
            --email)
                [[ -n "${2:-}" ]] || die "--email requires a value"
                EMAIL="$2"; _set_email=true; shift 2 ;;
            --primary-node)
                [[ -n "${2:-}" ]] || die "--primary-node requires a value"
                PRIMARY_NODE_OVERRIDE="$2"; shift 2 ;;
            --schedule)
                [[ -n "${2:-}" ]] || die "--schedule requires a value"
                UPDATE_SCHEDULE="$2"; _set_schedule=true; shift 2 ;;
            --weekday)
                [[ -n "${2:-}" ]] || die "--weekday requires a value"
                UPDATE_WEEKDAY="$2"; _set_weekday=true; shift 2 ;;
            --hour)
                [[ -n "${2:-}" ]] || die "--hour requires a value"
                UPDATE_HOUR="$2"; _set_hour=true; shift 2 ;;
            --config-dir)
                [[ -n "${2:-}" ]] || die "--config-dir requires a path argument"
                CONFIG_DIR="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  die "Unexpected argument: $1. Use --help for usage." ;;
        esac
    done

    [[ -n "$NAME" ]] || { error "--name <N> is required."; usage; exit 1; }
    # name must satisfy site-fields.json .name pattern ^[A-Za-z0-9_.-]+$
    [[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--name '${NAME}' invalid (must match ^[A-Za-z0-9_.-]+\$)."
}

# ---------------------------------------------------------------------------
# Validation of schedule inputs
# ---------------------------------------------------------------------------
validate_inputs() {
    case "$UPDATE_SCHEDULE" in
        monthly|weekly|daily|none) ;;
        *) die "Invalid --schedule: '$UPDATE_SCHEDULE'. Must be one of: monthly, weekly, daily, none" ;;
    esac
    case "$UPDATE_WEEKDAY" in
        Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|null) ;;
        *) die "Invalid --weekday: '$UPDATE_WEEKDAY'." ;;
    esac
    if ! [[ "$UPDATE_HOUR" =~ ^[0-9]+$ ]] || (( UPDATE_HOUR < 0 || UPDATE_HOUR > 23 )); then
        die "Invalid --hour: '$UPDATE_HOUR'. Must be an integer between 0 and 23."
    fi
    if [[ -n "$EMAIL" && "$EMAIL" != CHANGE* ]] \
       && ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        warn "Email '$EMAIL' may not be in a valid format."
    fi
}

# ---------------------------------------------------------------------------
# System-fact derivation (timezone / country / locale) — same logic and
# fallbacks as migrate-configuration.sh, so create + migrate agree.
# ---------------------------------------------------------------------------
detect_timezone() {
    local tz=""
    if command -v timedatectl >/dev/null 2>&1; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        local target
        target="$(readlink -f /etc/localtime 2>/dev/null || true)"
        tz="${target#*/zoneinfo/}"
        [[ "$tz" == "$target" ]] && tz=""
    fi
    if [[ -z "$tz" && -f /etc/timezone ]]; then
        tz="$(tr -d '[:space:]' < /etc/timezone 2>/dev/null || true)"
    fi
    [[ -n "$tz" ]] || tz="Europe/Amsterdam"
    printf '%s' "$tz"
}

country_from_timezone() {
    case "$1" in
        Europe/Amsterdam) echo "NL" ;;
        Europe/Copenhagen) echo "DK" ;;
        Europe/Berlin) echo "DE" ;;
        Europe/Brussels) echo "BE" ;;
        Europe/Paris) echo "FR" ;;
        Europe/London) echo "GB" ;;
        Europe/Madrid) echo "ES" ;;
        Europe/Rome) echo "IT" ;;
        America/*) echo "US" ;;
        *) echo "NL" ;;
    esac
}

detect_locale() {
    local loc=""
    if command -v localectl >/dev/null 2>&1; then
        loc="$(localectl status 2>/dev/null | sed -n 's/.*LANG=\([^ ]*\).*/\1/p' | head -1 || true)"
    fi
    [[ -z "$loc" ]] && loc="${LANG:-}"
    loc="${loc%%.*}"
    case "$loc" in ""|C|POSIX) loc="en_US" ;; esac
    printf '%s' "$loc"
}

# ---------------------------------------------------------------------------
# Discover admin email from the primary Proxmox node's root@pam user.cfg.
# (Only used when neither --email nor an existing site.json email is present.)
# ---------------------------------------------------------------------------
DISCOVERED_EMAIL=""
discover_node_email() {
    local primary_node="$1"
    local user_cfg
    user_cfg=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
        "grep '^user:root@pam:' /etc/pve/user.cfg 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$user_cfg" ]]; then
        local pve_email
        pve_email=$(echo "$user_cfg" | cut -d: -f7)
        if [[ -n "$pve_email" && "$pve_email" == *@* ]]; then
            DISCOVERED_EMAIL="$pve_email"
            debug "  Discovered email from Proxmox user.cfg: ${DISCOVERED_EMAIL}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Read existing site.json so a --force re-run preserves operator-set fields.
# ---------------------------------------------------------------------------
EXISTING_SITE=""          # whole existing site.json (compact), or ""
EXISTING_REPOS="[]"
EXISTING_EMAIL=""
EXISTING_PRIMARY_NODE=""
read_existing_site() {
    if [[ -f "$SITE_FILE" ]] && jq empty "$SITE_FILE" 2>/dev/null; then
        EXISTING_SITE="$(jq -c '.' "$SITE_FILE")"
        EXISTING_REPOS="$(jq -c '.repositories // []' "$SITE_FILE")"
        EXISTING_EMAIL="$(jq -r '.email // ""' "$SITE_FILE")"
        EXISTING_PRIMARY_NODE="$(jq -r '.hardware.nodes[0].name // ""' "$SITE_FILE")"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Cluster discovery — node list (replicates create-configuration.sh) plus the
# tankXY zpools physically present on each node (-> storagePools).
# ---------------------------------------------------------------------------
NODES=()
declare -A NODE_POOLS=()
discover_cluster() {
    info "Discovering Proxmox cluster nodes..."

    local primary_node
    if [[ -n "$PRIMARY_NODE_OVERRIDE" ]]; then
        primary_node="$PRIMARY_NODE_OVERRIDE"
    elif [[ -n "${EXISTING_PRIMARY_NODE:-}" ]]; then
        primary_node="${EXISTING_PRIMARY_NODE}.${MGMT}.internal"
    else
        primary_node="tappaas1.${MGMT}.internal"
    fi
    debug "  Primary node for discovery: ${primary_node}"

    # Email discovery (only if still unknown) from the primary node.
    if [[ -z "$EMAIL" && -z "$EXISTING_EMAIL" ]]; then
        discover_node_email "$primary_node"
    fi

    # Node list via pvesh JSON API (most reliable).
    local cluster_nodes=""
    cluster_nodes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
        "pvesh get /cluster/status --output-format=json 2>/dev/null | jq -r '[.[] | select(.type==\"node\")] | sort_by(.nodeid) | .[].name' | grep -v '^null$'" 2>/dev/null || true)

    # Fallback: pvecm nodes text parsing (handles the Qdevice/local layouts).
    if [[ -z "$cluster_nodes" ]]; then
        debug "  Falling back to pvecm nodes..."
        cluster_nodes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${primary_node}" \
            "pvecm nodes 2>/dev/null" 2>/dev/null | awk '
                /Name/ { for (i=1; i<=NF; i++) if ($i == "Name") name_col=i; next }
                /^[[:space:]]*[0-9]/ && name_col { print $name_col }
            ' | sed 's/ *(local)$//' || true)
    fi

    if [[ -z "$cluster_nodes" ]]; then
        warn "Could not discover cluster nodes (cluster unreachable?)."
        return 0
    fi

    info "  Found nodes: ${cluster_nodes}"

    for node in $cluster_nodes; do
        if [[ ! "$node" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            warn "Skipping invalid node name: '$node'"
            continue
        fi
        NODES+=("$node")

        # storagePools: the tankXY zpools actually present on the node. We query
        # the node directly (zpool list) — the cluster storage.cfg lists pools
        # cluster-wide even when not physically present on a node.
        local node_fqdn="${node}.${MGMT}.internal"
        local pools
        pools=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${node_fqdn}" \
            "zpool list -H -o name 2>/dev/null" 2>/dev/null | grep -E '^tank' | LC_ALL=C sort || true)
        NODE_POOLS["$node"]="$pools"
        debug "  ${node}: pools=[${pools//$'\n'/, }]"
    done

    info "  Total nodes: ${#NODES[@]}"
}

# ---------------------------------------------------------------------------
# Build hardware.nodes[] JSON from discovery.
# ---------------------------------------------------------------------------
build_nodes_json() {
    local node pools_arr
    local out="[]"
    (( ${#NODES[@]} == 0 )) && { printf '%s' "$out"; return 0; }
    for node in "${NODES[@]}"; do
        # Convert the newline-separated pool list to a JSON array.
        if [[ -n "${NODE_POOLS[$node]:-}" ]]; then
            pools_arr=$(printf '%s\n' "${NODE_POOLS[$node]}" | jq -R . | jq -s 'map(select(length>0))')
        else
            pools_arr='[]'
        fi
        out=$(jq -c --arg n "$node" --argjson p "$pools_arr" \
            '. + [{name: $n, storagePools: $p}]' <<<"$out")
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Resolve TAPPaaS version from git (same approach as create-configuration.sh).
# ---------------------------------------------------------------------------
resolve_version() {
    local v="1.0"
    if [[ -d "/home/tappaas/TAPPaaS/.git" ]]; then
        v=$(git -C /home/tappaas/TAPPaaS describe --tags --abbrev=0 2>/dev/null || echo "1.0")
    fi
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# Build the updateSchedule array [period, day, hour] (mirrors site.json shape).
# ---------------------------------------------------------------------------
build_schedule_json() {
    if [[ "$UPDATE_SCHEDULE" == "daily" ]]; then
        printf '["daily", null, %s]' "$UPDATE_HOUR"
    elif [[ "$UPDATE_SCHEDULE" == "none" ]]; then
        printf '["none", null, null]'
    else
        printf '["%s", "%s", %s]' "$UPDATE_SCHEDULE" "$UPDATE_WEEKDAY" "$UPDATE_HOUR"
    fi
}

# ---------------------------------------------------------------------------
# Build repositories[] — preserve existing operator-set repos, else default to
# the live TAPPaaS catalog entry (same shape as live site.json .repositories).
# ---------------------------------------------------------------------------
build_repos_json() {
    if [[ -n "$EXISTING_SITE" && "$EXISTING_REPOS" != "[]" ]]; then
        # Keep existing repos; refresh first repo's branch/url only when the
        # operator explicitly passed --branch / --upstream-git.
        jq -c \
            --arg url "$UPSTREAM_GIT" --arg branch "$BRANCH" \
            --argjson setUrl "$_set_upstream" \
            --argjson setBranch "$_set_branch" \
            'if length == 0 then .
             else
               (.[0].url    = (if $setUrl    then $url    else (.[0].url    // $url)    end))
               | (.[0].branch = (if $setBranch then $branch else (.[0].branch // $branch) end))
             end' <<<"$EXISTING_REPOS"
    else
        jq -nc --arg url "$UPSTREAM_GIT" --arg branch "$BRANCH" \
            '[{name: "TAPPaaS", url: $url, branch: $branch, path: "/home/tappaas/TAPPaaS", managed: "full", catalog: "src/module-catalog.json"}]'
    fi
}

# ---------------------------------------------------------------------------
# Build and write site.json.
# ---------------------------------------------------------------------------
build_and_write_site() {
    info "Generating site.json..."

    local tz country locale version nodes_json schedule_json repos_json email
    tz="$(detect_timezone)"
    country="$(country_from_timezone "$tz")"
    locale="$(detect_locale)"
    version="$(resolve_version)"
    nodes_json="$(build_nodes_json)"
    schedule_json="$(build_schedule_json)"
    repos_json="$(build_repos_json)"

    # Email precedence: explicit --email > existing site.json > Proxmox-discovered > "".
    if [[ -n "$EMAIL" ]]; then
        email="$EMAIL"
    elif [[ -n "$EXISTING_EMAIL" ]]; then
        email="$EXISTING_EMAIL"
    elif [[ -n "$DISCOVERED_EMAIL" ]]; then
        email="$DISCOVERED_EMAIL"
    else
        email=""
    fi

    # Preserved-from-existing operator fields (defaults on fresh install).
    # Note: use a real fallback var, NOT bash "${X:-{}}" — that expansion appends
    # a stray literal '}' (bash parses ${X:-{} + }) and breaks the jq input.
    local existing="${EXISTING_SITE:-}"
    [[ -n "$existing" ]] || existing='{}'
    local automaticReboot snapshotRetention owner displayName backup network location organizations
    automaticReboot="$(jq -r 'if .automaticReboot != null then (.automaticReboot|tostring) else "true" end' <<<"$existing")"
    snapshotRetention="$(jq -r 'if .snapshotRetention != null then (.snapshotRetention|tostring) else "5" end' <<<"$existing")"
    owner="$(jq -r --arg n "$NAME" '.owner // $n' <<<"$existing")"
    displayName="$(jq -r --arg n "$NAME" '.displayName // $n' <<<"$existing")"
    backup="$(jq -c '.backup // null' <<<"$existing")"
    network="$(jq -c '.network // {isp: null, publicIp: "auto"}' <<<"$existing")"
    organizations="$(jq -c '.organizations // []' <<<"$existing")"
    # location: keep existing if present, else freshly-detected
    location="$(jq -c --arg c "$country" --arg t "$tz" --arg l "$locale" \
        '.location // {country: $c, timezone: $t, locale: $l}' <<<"$existing")"
    # environments: preserve any already-registered environment refs
    local environments
    environments="$(jq -c '.environments // []' <<<"$existing")"

    mkdir -p "$CONFIG_DIR"
    TMP_SITE="$(mktemp "${SITE_FILE}.XXXXXX")"

    jq -n \
        --arg name "$NAME" \
        --arg displayName "$displayName" \
        --arg owner "$owner" \
        --arg email "$email" \
        --arg version "$version" \
        --argjson location "$location" \
        --argjson network "$network" \
        --argjson nodes "$nodes_json" \
        --argjson backup "$backup" \
        --argjson updateSchedule "$schedule_json" \
        --argjson automaticReboot "$automaticReboot" \
        --argjson snapshotRetention "$snapshotRetention" \
        --argjson repositories "$repos_json" \
        --argjson environments "$environments" \
        --argjson organizations "$organizations" \
        '{
            name: $name,
            displayName: $displayName,
            owner: $owner,
            email: $email,
            version: $version,
            location: $location,
            network: $network,
            hardware: { nodes: $nodes },
            backup: $backup,
            updateSchedule: $updateSchedule,
            automaticReboot: $automaticReboot,
            snapshotRetention: $snapshotRetention,
            repositories: $repositories,
            environments: $environments,
            organizations: $organizations
         }' > "$TMP_SITE"

    jq empty "$TMP_SITE" >/dev/null 2>&1 || die "Generated site.json is invalid JSON."

    mv "$TMP_SITE" "$SITE_FILE"
    TMP_SITE=""
    info "${GN:-}site.json written:${CL:-} ${SITE_FILE}"
}

# ---------------------------------------------------------------------------
# Post-write validation against site-fields.json via validate-site.sh.
# ---------------------------------------------------------------------------
run_validation() {
    [[ -x "$VALIDATE_SITE" ]] || { warn "validate-site.sh not found/executable — skipping validation."; return 0; }
    info "Validating site.json against site-fields.json..."
    if ! "$VALIDATE_SITE" --schema-dir "$SCHEMA_DIR" --quiet "$SITE_FILE"; then
        die "site.json failed schema validation (see errors above)."
    fi
    info "${GN:-}site.json passed schema validation.${CL:-}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_inputs

    CONFIG_DIR="${CONFIG_DIR%/}"
    SITE_FILE="${CONFIG_DIR}/site.json"

    # Idempotency guard.
    if [[ -f "$SITE_FILE" && "$FORCE" != "true" ]]; then
        die "site.json already exists at ${SITE_FILE} — refusing to overwrite (use --force)."
    fi

    read_existing_site || true

    [[ -n "$DOMAIN" ]] && debug "  --domain '${DOMAIN}' accepted but NOT written to site.json (per-environment)."

    discover_cluster
    build_and_write_site
    run_validation

    echo ""
    info "${GN:-}✓${CL:-} site.json created for '${NAME}' (${#NODES[@]} node(s) discovered)."
    info "Next steps:"
    info "  1. Review: cat ${SITE_FILE}"
    info "  2. Create the default environment (create-minimal-environments) with domain '${DOMAIN:-<set later>}'."
}

main "$@"
