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

# ── Output control (can be overridden by environment or callers) ────

[[ -z "${OPT_SILENT:-}" ]] && OPT_SILENT="${TAPPAAS_SILENT:-0}"
[[ -z "${OPT_DEBUG:-}"  ]] && OPT_DEBUG="${TAPPAAS_DEBUG:-0}"

# ── Logging functions ────────────────────────────────────────────────

info() {
    if [[ "${OPT_SILENT}" -eq 1 ]]; then return; fi
    echo -e "${DGN}[Info]${CL} $*";
}
debug() {
    if [[ "${OPT_DEBUG}" -ne 1 ]]; then return; fi
    echo -e "${BL}[Debug]${CL} $*";
}
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
error() { echo -e "${RD}[Error]${CL} $*" >&2; }
fatal() { echo -e "${RD}${BOLD}[Fatal]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Shared helper functions ──────────────────────────────────────────

# ── site.json source-of-truth helpers (ADR-007 S3b reader cutover) ───
# The authoritative site config is now `site.json`; readers fall back to the
# legacy `configuration.json` while both files coexist (the delete is a LATER
# phase — the fallback MUST stay until then). These helpers centralize the
# "read site.json, fall back to configuration.json" pattern so the bulk of the
# tree is migrated by migrating the helpers.

# Path to the live site.json (honours CONFIG_DIR override used in tests).
_site_json_path() { printf '%s\n' "${CONFIG_DIR}/site.json"; }
# Path to the legacy configuration.json (fallback source).
_config_json_path() { printf '%s\n' "${CONFIG_DIR}/configuration.json"; }

# Resolve the default environment name: the single non-mgmt environment, i.e.
# site.json .name. Falls back to the first DNS label of the legacy
# tappaas.domain, else "default".
default_environment_name() {
    local site cfg name=""
    site="$(_site_json_path)"
    cfg="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        name="$(jq -r '.name // empty' "$site" 2>/dev/null)" || name=""
    fi
    if [[ -z "$name" && -f "$cfg" ]]; then
        local domain
        domain="$(jq -r '.tappaas.domain // empty' "$cfg" 2>/dev/null)" || domain=""
        [[ -n "$domain" ]] && name="${domain%%.*}"
    fi
    [[ -n "$name" ]] || name="default"
    printf '%s\n' "$name"
}

# Resolve the path to an environment config file by environment name.
# Echoes the path if the file exists; returns 1 otherwise.
#   environment_file <env-name>
environment_file() {
    local env="$1"
    local p="${CONFIG_DIR}/environments/${env}.json"
    [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    return 1
}

# ── Node lookup helpers (read from site.json, fall back to configuration.json)
# These functions resolve node hostnames. site.json .hardware.nodes[].name is
# authoritative; the FQDN is always <name>.mgmt.internal (dns-hostname/ip no
# longer exist — name only). Falls back to configuration.json
# ."tappaas-nodes"[].hostname when site.json is absent, and to "tappaas1" when
# neither is available (e.g. during initial bootstrap).

# Get the actual system hostname of the Nth node (0-indexed).
# Arguments: [index] (default: 0)
get_node_hostname() {
    local index="${1:-0}"
    local site config name=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        name=$(jq -r --argjson i "$index" '.hardware.nodes[$i].name // empty' "$site" 2>/dev/null) || name=""
    fi
    if [[ -z "$name" && -f "$config" ]]; then
        name=$(jq -r --argjson i "$index" '."tappaas-nodes"[$i].hostname // empty' "$config" 2>/dev/null) || name=""
    fi
    [[ -n "$name" ]] || name="tappaas1"
    printf '%s\n' "$name"
}

# Get the dns-hostname of the Nth node (0-indexed). dns-hostname no longer
# exists as a distinct field — it is the node name. Kept for caller
# compatibility; identical to get_node_hostname.
# Arguments: [index] (default: 0)
get_node_dns_hostname() {
    get_node_hostname "${1:-0}"
}

# Get the FQDN of the primary (first) Proxmox node.
# Returns: <name>.mgmt.internal (e.g., tappaas1.mgmt.internal)
get_primary_node_fqdn() {
    printf '%s.mgmt.internal\n' "$(get_node_hostname 0)"
}

# Get all node hostnames, one per line. site.json first, then configuration.json.
get_all_node_hostnames() {
    local site config out=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        out=$(jq -r '.hardware.nodes[].name // empty' "$site" 2>/dev/null) || out=""
    fi
    if [[ -z "$out" && -f "$config" ]]; then
        out=$(jq -r '."tappaas-nodes"[].hostname // empty' "$config" 2>/dev/null) || out=""
    fi
    [[ -n "$out" ]] || out="tappaas1"
    printf '%s\n' "$out"
}

# Get the FQDN of the Nth node (0-indexed).
# Arguments: [index] (default: 0)
get_node_fqdn() {
    local index="${1:-0}"
    printf '%s.mgmt.internal\n' "$(get_node_hostname "$index")"
}

# Read a site-wide scalar field from site.json, falling back to a legacy
# .tappaas.<field> read on configuration.json. Echoes the raw value, or empty
# string when neither source has it.
#   get_site_value <site-jq-path> <legacy-tappaas-field>
# Example: get_site_value '.version' 'version'
get_site_value() {
    local site_path="$1" legacy_field="$2"
    local site config val=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        val=$(jq -r "${site_path} // empty" "$site" 2>/dev/null) || val=""
    fi
    if [[ -z "$val" && -f "$config" ]]; then
        val=$(jq -r --arg f "$legacy_field" '.tappaas[$f] // empty' "$config" 2>/dev/null) || val=""
    fi
    printf '%s' "$val"
}

# The installer/admin email (Let's Encrypt account, people bootstrap). Reads
# site.json .email, falls back to configuration.json .tappaas.email.
installer_email() {
    get_site_value '.email' 'email'
}

# Echo the .path of a named repository. Reads site.json .repositories[], falls
# back to configuration.json .tappaas.repositories[]. Empty if not found.
#   get_repo_path <repo-name>
get_repo_path() {
    local name="$1"
    local site config val=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        val=$(jq -r --arg n "$name" '.repositories[]? | select(.name==$n) | .path' "$site" 2>/dev/null | head -1) || val=""
    fi
    if [[ -z "$val" && -f "$config" ]]; then
        val=$(jq -r --arg n "$name" '.tappaas.repositories[]? | select(.name==$n) | .path' "$config" 2>/dev/null | head -1) || val=""
    fi
    printf '%s' "$val"
}

# Whether TAPPaaS may perform automated reboots (Proxmox node kernel reboots and
# the firewall/identity VM reboots). Reads site.json .automaticReboot; falls
# back to configuration.json .tappaas.automaticReboot. Defaults to true when
# unset or both files are missing. Returns 0 (enabled) or 1 (disabled). Shared
# gate for all reboot sites (#275).
automatic_reboot_enabled() {
    local site config val=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    # NB: do NOT use jq's `// true` here — `false // true` yields true.
    # Read the raw value; null/missing means "use the default (true)".
    if [[ -f "$site" ]]; then
        val=$(jq -r '.automaticReboot' "$site" 2>/dev/null) || val=""
    fi
    if [[ ( -z "$val" || "$val" == "null" ) && -f "$config" ]]; then
        val=$(jq -r '.tappaas.automaticReboot' "$config" 2>/dev/null) || val=""
    fi
    # Enabled unless explicitly set to false.
    [[ "$val" != "false" ]]
}

# How many pre-update VM snapshots update-module.sh keeps per module. Reads
# site.json .snapshotRetention; falls back to configuration.json
# .tappaas.snapshotRetention. Defaults to 5 when unset, missing, or not a
# positive integer. Echoes the count. Paired with snapshot-vm.sh --cleanup to
# bound per-VM snapshot chains (#353).
snapshot_retention() {
    local site config val=""
    site="$(_site_json_path)"
    config="$(_config_json_path)"
    if [[ -f "$site" ]]; then
        val=$(jq -r '.snapshotRetention // empty' "$site" 2>/dev/null) || val=""
    fi
    if [[ -z "$val" && -f "$config" ]]; then
        val=$(jq -r '.tappaas.snapshotRetention // empty' "$config" 2>/dev/null) || val=""
    fi
    # Accept only a positive integer; otherwise fall back to the default.
    if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 1 ]]; then
        echo "$val"
    else
        echo 5
    fi
}

# Get the first node whose hostname differs from the given primary node.
# Used to resolve a default HANode when none is explicitly set. Reads from
# site.json (.hardware.nodes), falls back to configuration.json (.tappaas-nodes).
# Arguments: [primary-node-hostname] (default: first node)
get_default_ha_node() {
    local primary="${1:-$(get_node_hostname 0)}"
    get_all_node_hostnames | grep -vx "$primary" | head -1
}

# ── Module helper functions ──────────────────────────────────────────

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
# Path to the runtime cert-refid state file (ADR-007c). Maps environment-name ->
# OPNsense Trust refid for the env's wildcard cert. Reconciler/acme-setup writes
# it; readers consume it. NOT authored config.
cert_refids_path() { printf '%s\n' "${CONFIG_DIR}/cert-refids.json"; }

# Look up the TLS cert refid for an environment, preferring the runtime
# cert-refids.json (keyed by env name), then falling back to the legacy
# configuration.json fields (.tappaas.variants[<env>].tlsCertRefid for non-empty
# envs / default env, plus .tappaas.tlsCertRefid for the default). Echoes the
# refid or empty string.
#   cert_refid_for_env <env-name>
cert_refid_for_env() {
    local env="$1"
    local crf cfg refid=""
    crf="$(cert_refids_path)"
    cfg="$(_config_json_path)"
    if [[ -f "$crf" ]]; then
        refid=$(jq -r --arg e "$env" '.[$e] // empty' "$crf" 2>/dev/null) || refid=""
    fi
    if [[ -z "$refid" && -f "$cfg" ]]; then
        # Legacy: the variant key was the variant name; the default env maps to
        # the "" variant and the top-level .tappaas.tlsCertRefid alias.
        local default_env
        default_env="$(default_environment_name)"
        if [[ "$env" == "$default_env" ]]; then
            refid=$(jq -r '(.tappaas.variants[""].tlsCertRefid // .tappaas.tlsCertRefid) // empty' "$cfg" 2>/dev/null) || refid=""
        else
            refid=$(jq -r --arg e "$env" '.tappaas.variants[$e].tlsCertRefid // empty' "$cfg" 2>/dev/null) || refid=""
        fi
    fi
    printf '%s' "$refid"
}

# Read an environment's configuration (ADR-007 reader cutover). The "variant"
# name IS the environment name; "" means the default environment (the single
# non-mgmt environment = site.json .name). Echoes a normalized JSON object with
# the SAME shape readers expect:
#   {domain, tlsCertRefid, dnsMode, zone, description}
# sourced from config/environments/<env>.json:
#   domain      <- .domains.primary
#   dnsMode     <- .domains.dnsMode (default "wildcard")
#   zone        <- .network.zone
#   description <- .displayName
#   tlsCertRefid<- runtime cert-refids.json (cert_refid_for_env)
# Falls back to the legacy configuration.json (.tappaas.variants[<v>] /
# .tappaas.domain) when the environment file is absent, so un-migrated installs
# keep working. Returns 1 if neither source resolves.
#   get_variant_config <variant-name>   (use "" for the default environment)
get_variant_config() {
    local variant="$1"
    local env env_file refid

    # Resolve the environment name: explicit variant, else the default env.
    if [[ -n "$variant" ]]; then
        env="$variant"
    else
        env="$(default_environment_name)"
    fi

    # 1. New source: environment file + runtime cert-refids.json.
    if env_file="$(environment_file "$env")"; then
        refid="$(cert_refid_for_env "$env")"
        jq -c --arg refid "$refid" '
            { domain:       (.domains.primary // ""),
              tlsCertRefid: $refid,
              dnsMode:      (.domains.dnsMode // "wildcard"),
              zone:         (.network.zone // null),
              description:  (.displayName // "") }' "$env_file"
        return 0
    fi

    # 2. Legacy fallback — configuration.json variant registry / tappaas.domain.
    local cfg
    cfg="$(_config_json_path)"
    if [[ -f "${cfg}" ]]; then
        if jq -e --arg v "${variant}" '(.tappaas.variants // {})[$v] // empty' "${cfg}" >/dev/null 2>&1; then
            jq -c --arg v "${variant}" '
                (.tappaas.variants // {})[$v]
                | { domain:       .domain,
                    tlsCertRefid: (.tlsCertRefid // ""),
                    dnsMode:      (.dnsMode // "wildcard"),
                    zone:         (.zone // null),
                    description:  (.description // "") }' "${cfg}"
            return 0
        fi
        if [[ -z "${variant}" ]]; then
            local legacy_domain
            legacy_domain=$(jq -r '.tappaas.domain // empty' "${cfg}")
            if [[ -n "${legacy_domain}" ]]; then
                warn "tappaas.domain is deprecated (ADR-005/ADR-007). Migrate to config/environments/." >&2
                jq -c '{ domain:       .tappaas.domain,
                         tlsCertRefid: (.tappaas.tlsCertRefid // ""),
                         dnsMode:      "wildcard",
                         zone:         null,
                         description:  "Default (legacy tappaas.domain)" }' "${cfg}"
                return 0
            fi
        fi
    fi

    error "Environment '${env}' not found (no config/environments/${env}.json, no legacy configuration.json fallback)"
    return 1
}

# Push the deployed zones.json to every Proxmox node's /root/tappaas/zones.json so
# node-side tooling (Create-TAPPaaS-VM.sh) can resolve a newly-added zone's VLAN
# tag. Without this, installing a module into a freshly-created zone fails with
# `get_vlan_value "<zone>"` on the node. Returns non-zero if nothing was pushed.
distribute_zones_to_nodes() {
    local zones="${CONFIG_DIR}/zones.json"
    [[ -f "${zones}" ]] || { warn "distribute_zones_to_nodes: missing zones.json"; return 1; }
    local node pushed=0
    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        if scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
                "${zones}" "root@${node}.mgmt.internal:/root/tappaas/zones.json" >/dev/null 2>&1; then
            pushed=$((pushed + 1))
        fi
    done < <(get_all_node_hostnames 2>/dev/null)
    info "  Distributed zones.json to ${pushed} Proxmox node(s)"
    [[ "${pushed}" -gt 0 ]]
}

# Compute the DMZ gateway IP (the firewall's DMZ interface, where the os-caddy
# reverse proxy listens) from zones.json — e.g. dmz ip 10.6.0.0/24 -> 10.6.0.1.
# Used for split-horizon DNS so internal clients reach Caddy over the DMZ instead
# of routing out via the WAN and tripping Caddy's zone ACL (#269, ADR-005 §6).
# Never hardcode the IP — it is derived from the live zones.json.
dmz_gateway_ip() {
    local zones="${CONFIG_DIR}/zones.json"
    [[ -f "${zones}" ]] || { error "zones.json not found at ${zones}"; return 1; }
    local gw
    gw="$(jq -r '(.dmz.ip // "") | if . == "" then "" else (split("/")[0] | split(".") | .[0:3] | join(".") + ".1") end' "${zones}")"
    [[ -n "${gw}" ]] || { error "could not derive DMZ gateway IP from ${zones} (no dmz zone?)"; return 1; }
    printf '%s\n' "${gw}"
}

# Resolve a dependency's provider module name, honoring variant preference
# (#292, ADR-005 §4). Given a bare provider name and the installing module's
# variant, prefer an installed same-variant provider `<provider>-<variant>.json`
# and otherwise fall back to the base `<provider>.json`. Always echoes a name:
# the same-variant name when its config exists, else the base name (the caller
# validates that the resolved config actually exists). With an empty variant this
# is a no-op that returns the base name, so default installs behave exactly as
# before.
#   resolve_provider_module <provider> [variant]
resolve_provider_module() {
    local provider="$1" variant="${2:-}"
    if [[ -n "${variant}" && -f "${CONFIG_DIR}/${provider}-${variant}.json" ]]; then
        echo "${provider}-${variant}"
    else
        echo "${provider}"
    fi
}

check_service_available() {
    local dep="$1"
    local required_script="${2:-install-service.sh}"
    # Optional installing-variant: when set, a same-variant provider config is
    # preferred over the base one (#292). Empty → legacy behavior (base only).
    local variant="${3:-}"
    local service_name="${dep##*:}"
    local provider_module
    provider_module="$(resolve_provider_module "${dep%%:*}" "${variant}")"
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

# Check whether a VM with the given VMID exists anywhere in the Proxmox cluster.
# VMIDs are cluster-wide, so a VM created on any node makes the ID unavailable —
# this queries /cluster/resources rather than a single node's `qm status`.
#
# Arguments:
#   $1  VMID to look for
#   $2  FQDN of any reachable cluster node (used only to enter the cluster)
#
# On success (VM found) echoes the node the VM lives on and returns 0.
# Returns 1 if no such VMID is found in the cluster.
vm_exists_on_cluster() {
    local vmid="$1"
    local node_fqdn="$2"
    local found_node

    found_node=$(ssh -o ConnectTimeout=5 root@"${node_fqdn}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
        | jq -r --argjson id "${vmid}" '.[] | select(.vmid == $id) | .node // empty' 2>/dev/null) \
        || found_node=""

    if [[ -n "${found_node}" ]]; then
        echo "${found_node}"
        return 0
    fi
    return 1
}

# Determine whether a module already appears to be installed on the cluster.
#
# A module is considered installed when its config JSON is present in CONFIG_DIR
# (this is the marker dropped by Step 1 of a previous install). For VM-backed
# modules (those declaring a "cluster:vm" dependency) the config alone is not
# trusted: the VM is probed cluster-wide, so a leftover config whose VM is gone
# is treated as NOT installed (stale), allowing a clean re-install.
#
# Arguments:
#   $1  Effective module name (e.g. "identity" or "openwebui-dev")
#
# Returns 0 if the module appears installed, 1 otherwise.
module_exists() {
    local module="$1"
    local cfg="${CONFIG_DIR}/${module}.json"

    # No config in CONFIG_DIR => never installed.
    [[ -f "${cfg}" ]] || return 1

    # Guest-backed module (cluster:vm or cluster:lxc): verify the guest below.
    # Any other module (service-only): config presence is the only signal we
    # have, so treat it as installed. (Note: install-module sources this file
    # from the module dir, which auto-copies <module>.json into CONFIG_DIR — so
    # config presence alone cannot distinguish "installed" from "about to
    # install" for guest-backed modules; we must probe the cluster. Issue #203.)
    if ! jq -e '(.dependsOn // []) | (index("cluster:vm") != null) or (index("cluster:lxc") != null)' "${cfg}" >/dev/null 2>&1; then
        return 0
    fi

    # Guest-backed module: confirm the VM/container is actually on the cluster
    # (pvesh --type vm returns both qemu and lxc guests).
    local vmid node node_fqdn found_node
    vmid=$(jq -r '.vmid // empty' "${cfg}" 2>/dev/null)
    node=$(jq -r '.node // empty' "${cfg}" 2>/dev/null)
    [[ -z "${node}" ]] && node="$(get_node_hostname 0)"
    node_fqdn="${node}.mgmt.internal"

    # Config declares cluster:vm but has no vmid — can't probe; trust the config.
    if [[ -z "${vmid}" ]]; then
        return 0
    fi

    if found_node=$(vm_exists_on_cluster "${vmid}" "${node_fqdn}"); then
        info "  Found VM ${BL}${vmid}${CL} (${module}) on node ${BL}${found_node}${CL}"
        return 0
    fi

    warn "  Config ${cfg} exists but VM ${vmid} not found on the cluster — treating '${module}' as not installed (stale config)"
    return 1
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
            errors=$((errors + 1))
            continue
        fi

        if [[ ! -x "${svc_dir}/install-service.sh" ]]; then
            error "Module provides '${service}' but missing install-service.sh in ${svc_dir}"
            errors=$((errors + 1))
        fi

        if [[ ! -x "${svc_dir}/update-service.sh" ]]; then
            error "Module provides '${service}' but missing update-service.sh in ${svc_dir}"
            errors=$((errors + 1))
        fi
    done

    return "${errors}"
}

# Validate that the module's zone0 is Active in zones.json.
# Early-exit guard: called before any provisioning action in install-module.sh.
# Arguments:
#   $1  zone name (e.g. srvWork)
# Returns 1 if zone is missing or not Active; 0 if Active or zones.json absent.
validate_zone_active() {
    local zone="$1"
    local zones_file="${CONFIG_DIR}/zones.json"
    local state

    if [[ ! -f "$zones_file" ]]; then
        warn "zones.json not found at $zones_file — skipping zone state check"
        return 0
    fi

    if ! jq -e --arg z "$zone" 'has($z)' "$zones_file" > /dev/null 2>&1; then
        error "Zone '${YW}${zone}${CL}' not found in zones.json"
        return 1
    fi

    state=$(jq -r --arg z "$zone" '.[$z].state // "unknown"' "$zones_file")

    # Deployable states — the zone's network actually exists, so a module placed
    # in it will have connectivity:
    #   Active     zone-manager-managed (VLAN + DHCP + rules created in OPNsense)
    #   Manual     operator-managed; zone-manager leaves it alone. The mgmt
    #              control plane (VLAN 0) is Manual by design and hosts the
    #              foundation modules (firewall, cicd, backup, identity, logging).
    #   Mandatory  always-on, cannot be disabled (e.g. dmz)
    # Non-deployable: Inactive (defined but not yet created) and Disabled (being
    # torn down) — provisioning there would leave the module without a network.
    case "$state" in
        Active|Manual|Mandatory)
            info "  ${GN}✓${CL} Zone '${zone}' is ${state} (deployable)"
            return 0
            ;;
    esac

    error "Zone '${YW}${zone}${CL}' is ${YW}${state}${CL} — cannot deploy module before zone is activated"
    error ""
    error "  Options:"
    error "    1. Activate the zone (upstream PR + Lars review required):"
    error "         zone-state.sh enable ${zone}"
    error "         zone-manager --execute"
    error "    2. Redeploy to an already-active zone:"
    error "         install-module.sh <module> --zone0 <active-zone>"
    return 1
}

# ── OPNsense module alias naming (#300, ADR-005 #316) ────────────────
# firewall:rules provisions an OPNsense alias `tm_<vmname>` for a module. OPNsense
# alias names must match ^[a-zA-Z_][a-zA-Z0-9_]{0,31}$ — at most 32 chars. This
# MUST stay byte-identical to rules_manager._module_alias_name (Python), the
# authority that actually creates the alias.
#
# Scheme: short `tm_` prefix + sanitise (non-alphanumeric -> underscore). A vmname
# (incl. variant suffix) under MODULE_ALIAS_HASH_THRESHOLD chars gets the plain
# `tm_<sanitised>` alias; at/above it the alias is a readable prefix + 6-hex sha1
# of the FULL vmname (deterministic, collision-free) so long names still fit 32.
MODULE_ALIAS_PREFIX="tm_"
MODULE_ALIAS_HASH_THRESHOLD=28
module_alias_name() {
    local vmname="$1"
    local sanitised digest keep
    sanitised="${vmname//[^a-zA-Z0-9]/_}"
    if [[ "${#vmname}" -lt "${MODULE_ALIAS_HASH_THRESHOLD}" ]]; then
        printf '%s\n' "${MODULE_ALIAS_PREFIX}${sanitised}"
        return 0
    fi
    digest="$(printf '%s' "${vmname}" | sha1sum | cut -c1-6)"
    keep=$(( 32 - ${#MODULE_ALIAS_PREFIX} - 1 - ${#digest} ))
    printf '%s_%s\n' "${MODULE_ALIAS_PREFIX}${sanitised:0:keep}" "${digest}"
}

# Announce the alias a vmname will get. A vmname at/above the hash threshold gets a
# hashed alias rather than being rejected (superseding #300's fail-fast); this
# never blocks — it only warns so the operator knows the firewall alias won't be
# the literal vmname.
validate_module_alias_name() {
    local vmname="$1" alias_name
    alias_name="$(module_alias_name "${vmname}")"
    if [[ "${#vmname}" -ge "${MODULE_ALIAS_HASH_THRESHOLD}" ]]; then
        warn "vmname '${vmname}' is ${#vmname} chars (>= ${MODULE_ALIAS_HASH_THRESHOLD}); its OPNsense alias is hashed to '${alias_name}'"
    fi
    return 0
}

# ── ACME DNS provider → os-acme-client key resolution (#327) ─────────────
# acme-setup.sh accepts a friendly --provider name (cloudflare, route53, ...) and
# passes it to acme-manager, which translates it to the os-acme-client `dns_service`
# key. acme.sh's dnsapi hook file is named after that RESOLVED key, not the friendly
# name (cloudflare→dns_cf.sh, route53→dns_aws.sh, powerdns→dns_pdns.sh), so the
# preflight hook check must resolve first or it false-negatives the default provider.
# This MUST stay in sync with PROVIDER_ALIASES in opnsense-controller's acme_cli.py,
# the authority that actually drives os-acme-client.
resolve_dns_service() {
    local provider="$1"
    case "$provider" in
        dns_*)       printf '%s\n' "$provider" ;;
        cloudflare)  printf 'dns_cf\n' ;;
        desec)       printf 'dns_desec\n' ;;
        hetzner)     printf 'dns_hetzner\n' ;;
        ovh)         printf 'dns_ovh\n' ;;
        route53|aws) printf 'dns_aws\n' ;;
        namecheap)   printf 'dns_namecheap\n' ;;
        namecom)     printf 'dns_namecom\n' ;;
        godaddy)     printf 'dns_godaddy\n' ;;
        powerdns)    printf 'dns_pdns\n' ;;
        njalla)      printf 'dns_njalla\n' ;;
        inwx)        printf 'dns_inwx\n' ;;
        gandi)       printf 'dns_gandi\n' ;;
        he)          printf 'dns_he\n' ;;
        *)           printf 'dns_%s\n' "$provider" ;;
    esac
}

# ── Module-config normalization (#161 / #207) ────────────────────────
# Defined here (before auto-load) so the auto-load block below can call it.
# A module JSON may group per-service configuration under a Pattern-A `config`
# block keyed by the "<module>:<service>" dependency coordinate. Normalize
# flattens every config block up to the top level so all downstream tooling
# reads flat top-level fields. Pattern-C (already-flat) modules pass through
# unchanged. Reads JSON on stdin, emits normalized JSON on stdout.
function normalize_module_config() {
  jq '
    if (.config | type) == "object"
    then reduce (.config | to_entries[]) as $s (.; . * $s.value) | del(.config)
    else . end
  '
}

# ── Auto-load JSON configuration ─────────────────────────────────────
# If $1 (module/vm name) is provided, attempt to load its JSON config
# into the $JSON variable.  Silently skipped when $1 is empty or the
# config file does not exist (callers that need get_config_value but
# don't pass a module name via $1 can load JSON themselves after sourcing).
#
# IMPORTANT: this only *reads* JSON into $JSON; it must never copy the file
# into CONFIG_DIR. A sourced script inherits the caller's positional args, so
# `install-module.sh <mod>` sourcing this file would otherwise plant
# CONFIG_DIR/<mod>.json before Step 1's "already installed?" check runs —
# producing a spurious "stale config" warning and bypassing the validated copy
# that copy-update-json.sh performs in Step 2. The CONFIG_DIR copy is the sole
# responsibility of copy-update-json.sh.

if [[ -n "${1:-}" ]]; then
    JSON_CONFIG="${CONFIG_DIR}/${1}.json"
    if [[ -f "${JSON_CONFIG}" ]]; then
        # Always present $JSON in flat (normalized) form so get_config_value
        # works regardless of whether the on-disk shape is flat or Pattern A (#207).
        JSON=$(normalize_module_config < "${JSON_CONFIG}")
    elif [[ -f "${1}.json" ]]; then
        JSON=$(normalize_module_config < "${1}.json")
    fi
fi

# ── Config access ────────────────────────────────────────────────────

# Read a value from the loaded JSON config (requires $JSON to be set).
# Arguments: <key> [default-value]
#
# A default is considered "provided" when a second argument is passed at all —
# even an empty string. This lets callers mark a key as optional-with-empty
# default, e.g. get_config_value 'HANode' "$(get_default_ha_node "$NODE")",
# which yields "" on a single-node cluster instead of aborting (issues #1/#5
# of #166). Omitting the second argument entirely still means "required".
function get_config_value() {
  local key="$1"
  local has_default=0
  local default=""
  if [[ $# -ge 2 ]]; then has_default=1; default="$2"; fi
  if ! echo "$JSON" | jq -e --arg K "$key" 'has($K)' >/dev/null ; then
    # JSON lacks the key
    if [[ "${has_default}" -eq 0 ]]; then
      error "Missing required key '${YW}$key${CL}' in JSON configuration."
      exit 1
    else
      value="$default"
    fi
  else
    value=$(echo "$JSON" | jq -r --arg KEY "$key" '.[$KEY]')
  fi
  debug "     - $key has value: ${BGN}${value}${CL}" >&2
  echo -n "${value}"
  return 0
}

# Read a module's installed config in normalized flat form (#207).
# Usage: read_module_config <module-name>
# Output: flat JSON on stdout. Accepts either Pattern A or flat on disk; output is always flat.
# All consumers should use this helper instead of `jq … "${CONFIG_DIR}/<m>.json"` so the
# on-disk format can evolve without breaking readers.
function read_module_config() {
  local m="$1"
  local p="${CONFIG_DIR}/${m}.json"
  if [[ ! -f "$p" ]]; then
    error "Module config not found: $p" >&2
    return 1
  fi
  normalize_module_config < "$p"
}

# Apply a jq filter against a module's installed config and write the result
# back atomically (#207). Always reads in Pattern A or flat, writes in the
# canonical Pattern A form via convert-json-to-config.sh (sourced on demand).
# Usage: jq_module_write <module> <jq-filter> [jq-args...]
function jq_module_write() {
  local m="$1"; shift
  local filter="$1"; shift
  local p="${CONFIG_DIR}/${m}.json"
  if [[ ! -f "$p" ]]; then
    error "Module config not found: $p" >&2
    return 1
  fi
  # Source the converter the first time we need it. Prefer the live ~/bin
  # symlink (refreshed by pre-update.sh) and fall back to the repo path.
  if ! declare -F regroup_to_pattern_a >/dev/null 2>&1; then
    local _cv
    for _cv in /home/tappaas/bin/convert-json-to-config.sh \
               /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/convert-json-to-config.sh; do
      if [[ -f "$_cv" ]]; then
        # shellcheck disable=SC1090
        . "$_cv" && break
      fi
    done
    declare -F regroup_to_pattern_a >/dev/null 2>&1 \
      || { error "convert-json-to-config.sh not found — required for Pattern A writes" >&2; return 1; }
  fi
  local tmp; tmp="$(mktemp)"
  if normalize_module_config < "$p" \
     | jq "$@" "$filter" \
     | regroup_to_pattern_a > "$tmp" 2>/dev/null \
     && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$p"
  else
    rm -f "$tmp"
    error "jq_module_write failed for $m with filter: $filter" >&2
    return 1
  fi
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
    error "JSON file not found: ${YW}$json_file${CL}"
    return 1
  fi

  if [ ! -f "$schema_file" ]; then
    error "Schema file not found: ${YW}$schema_file${CL}"
    return 1
  fi

  # Parse the JSON file
  local json_content
  if ! json_content=$(jq '.' "$json_file" 2>&1); then
    error "Invalid JSON syntax in ${YW}$json_file${CL}"
    error "       ${json_content}"
    return 1
  fi

  # Pattern C (#161): accept a Pattern-A `config` block (per-service config
  # keyed by the "<module>:<service>" dependency coordinate). Validate its
  # structure, then flatten to the flat internal representation so the rest of
  # validation (field names/types/requiredBy) runs unchanged.
  if echo "$json_content" | jq -e '(.config | type) == "object"' >/dev/null 2>&1; then
    # 1. Every config key must be a declared dependency.
    local undeclared
    undeclared=$(echo "$json_content" | jq -r '
      (.dependsOn // []) as $d | .config | keys[] | select(. as $k | ($d | index($k)) | not)')
    if [[ -n "$undeclared" ]]; then
      while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        error "  config block '${YW}${k}${CL}' is not a declared dependency — add it to dependsOn (#161)"
        errors=$((errors + 1))
      done <<< "$undeclared"
    fi
    # 2. No field may appear in both the header and a config block, or in two
    #    config blocks (ambiguous after flattening — the drift #161 prevents).
    local collisions
    collisions=$(echo "$json_content" | jq -r '
      [ (del(.config) | keys[]), ((.config // {}) | .[] | keys[]) ]
      | group_by(.) | map(select(length > 1) | .[0]) | .[]' 2>/dev/null)
    if [[ -n "$collisions" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        error "  field '${YW}${f}${CL}' is set in both the header and a config block (or in two config blocks) — ambiguous (#161)"
        errors=$((errors + 1))
      done <<< "$collisions"
    fi
    # 3. Flatten for the remaining validation.
    json_content=$(echo "$json_content" | normalize_module_config)
  fi

  # Load schema fields
  local schema_fields
  schema_fields=$(jq '.fields' "$schema_file")

  debug "Validating: $json_file"

  # Check fields required by dependencies (requiredBy vs dependsOn)
  local depends_on_json
  depends_on_json=$(echo "$json_content" | jq -c '.dependsOn // []')

  # A module is either VM-backed or container-backed, never both (issue #203).
  if echo "$depends_on_json" | jq -e 'index("cluster:vm") != null and index("cluster:lxc") != null' >/dev/null 2>&1; then
    error "  dependsOn declares both ${YW}cluster:vm${CL} and ${YW}cluster:lxc${CL} — a guest is a VM or a container, not both"
    errors=$((errors + 1))
  fi

  # Fields with a "default" in the schema are never strictly required — the
  # installer can fall back to the default, so only flag fields that have
  # requiredBy but NO default.
  local required_fields
  required_fields=$(echo "$schema_fields" | jq -r --argjson deps "$depends_on_json" '
    to_entries[] |
    select(
      (.value.requiredBy // []) as $rb |
      ($rb | length > 0) and
      ([$rb[] as $r | $deps[] | select(. == $r)] | length > 0) and
      (.value | has("default") | not)
    ) |
    .key')

  for field in $required_fields; do
    if ! echo "$json_content" | jq -e --arg F "$field" 'has($F)' >/dev/null 2>&1; then
      local req_by
      req_by=$(echo "$schema_fields" | jq -r --arg F "$field" --argjson deps "$depends_on_json" '
        .[$F].requiredBy as $rb | [$rb[] as $r | $deps[] | select(. == $r)] | join(", ")')
      error "  Missing field: ${YW}$field${CL} (required by ${req_by})"
      errors=$((errors + 1))
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
      warn "  Unknown field: ${YW}$key${CL} (not in schema)"
      warnings=$((warnings + 1))
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
          error "  Field ${YW}$key${CL}: expected integer, got '${value}'"
          errors=$((errors + 1))
        else
          # Check minimum
          local min
          min=$(echo "$field_schema" | jq -r '.minimum // empty')
          if [ -n "$min" ] && [ "$value" -lt "$min" ]; then
            error "  Field ${YW}$key${CL}: value $value is below minimum $min"
            errors=$((errors + 1))
          fi
          # Check maximum
          local max
          max=$(echo "$field_schema" | jq -r '.maximum // empty')
          if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
            error "  Field ${YW}$key${CL}: value $value exceeds maximum $max"
            errors=$((errors + 1))
          fi
        fi
        ;;

      "string")
        # Check pattern if defined
        local pattern
        pattern=$(echo "$field_schema" | jq -r '.pattern // empty')
        if [ -n "$pattern" ]; then
          if ! [[ "$value" =~ $pattern ]]; then
            error "  Field ${YW}$key${CL}: value '${value}' does not match pattern '${pattern}'"
            errors=$((errors + 1))
          fi
        fi

        # Check format if defined (regexp-based format validation)
        local format
        format=$(echo "$field_schema" | jq -r '.format // empty')
        if [ -n "$format" ]; then
          if ! [[ "$value" =~ $format ]]; then
            error "  Field ${YW}$key${CL}: value '${value}' does not match format '${format}'"
            errors=$((errors + 1))
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
            error "  Field ${YW}$key${CL}: invalid value '${value}'"
            error "           Allowed values: ${valid_values//$'\n'/, }"
            errors=$((errors + 1))
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
      error "  Field ${YW}imageLocation${CL} is required when imageType is '${image_type}'"
      errors=$((errors + 1))
    fi
  fi

  # Check HANode is different from node if specified
  local ha_node
  ha_node=$(echo "$json_content" | jq -r '.HANode // empty')
  local node
  node=$(echo "$json_content" | jq -r '.node // empty')
  [[ -z "$node" ]] && node="$(get_node_hostname 0)"
  if [[ -n "$ha_node" ]] && [[ "$ha_node" == "$node" ]]; then
    error "  HANode (${ha_node}) must be different from node (${node})"
    errors=$((errors + 1))
  fi
  # Validate HANode exists among the configured nodes if set (site.json first,
  # configuration.json fallback — via get_all_node_hostnames).
  if [[ -n "$ha_node" ]]; then
    local known_nodes
    known_nodes=$(get_all_node_hostnames 2>/dev/null)
    if ! echo "$known_nodes" | grep -qx "$ha_node"; then
      warn "  HANode '${ha_node}' not found among configured nodes (site.json/configuration.json)"
      warnings=$((warnings + 1))
    fi
  fi

  # Check zone references exist in zones.json
  local zones_file="/home/tappaas/config/zones.json"
  if [ -f "$zones_file" ]; then
    for zone_field in zone0 zone1; do
      local zone_value
      zone_value=$(echo "$json_content" | jq -r --arg Z "$zone_field" '.[$Z] // empty')
      if [ -n "$zone_value" ]; then
        if ! jq -e --arg Z "$zone_value" 'has($Z)' "$zones_file" >/dev/null 2>&1; then
          error "  Field ${YW}$zone_field${CL}: zone '${zone_value}' not found in zones.json"
          errors=$((errors + 1))
        fi
      fi
    done
  fi

  # Summary
  if [ $errors -gt 0 ]; then
    error "Validation failed: $errors error(s), $warnings warning(s)"
    return 1
  elif [ $warnings -gt 0 ]; then
    warn "Validation passed with warnings: $warnings warning(s)"
    return 0
  else
    info "Validation passed: No errors or warnings"
    return 0
  fi
}
