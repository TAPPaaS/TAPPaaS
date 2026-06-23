# shellcheck shell=bash
# lib-cascade.sh — the Site -> Environment -> Module backup-policy cascade
# resolver (ADR-007 P9), sourced by backup-manager.sh / backup-status.sh /
# validate-backup.sh. Pure config reads from CONFIG_DIR; never mutates state and
# never contacts PBS — so it is fully unit-testable against fixtures.
#
# Cascade precedence (most specific wins):
#   retention : module.backup.retention > environment.backup.retention
#               > site.backup.defaultRetention > "7y"
#   residency : module has none; environment.backup.residency
#               > environment.dataResidency > "eu-only"
#   enabled   : module.backup.enabled (default true)
#   exclude   : module.backup.exclude (default [])
#   target    : site.backup.target
#   offsite   : site.backup.offsite
#   schedule  : environment.backup.schedule > null (inherit site job)
#
# The effective policy is printed as a single JSON object so callers (status,
# install-module persistence, health checks) consume it uniformly.

# CONFIG_DIR is overridable for fixtures/tests; defaults to the live config dir.
CASCADE_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# Path to the site config (site.json), or empty if absent.
_bc_site_file() {
    local f="${CASCADE_CONFIG_DIR}/site.json"
    [[ -f "$f" ]] && printf '%s\n' "$f"
}

# Path to an environment's JSON, or empty if absent. mgmt is a valid environment
# even without a file (foundation default) — callers treat "no file" as no
# environment overrides.
_bc_env_file() {
    local env="$1" f
    [[ -n "$env" ]] || return 0
    f="${CASCADE_CONFIG_DIR}/environments/${env}.json"
    [[ -f "$f" ]] && printf '%s\n' "$f"
}

# Resolve the environment name for a deployed module: explicit override ($2),
# else the module config's .environment, else empty.
bc_module_environment() {
    local module="$1" override="${2:-}" mfile
    if [[ -n "$override" ]]; then printf '%s\n' "$override"; return 0; fi
    mfile="${CASCADE_CONFIG_DIR}/${module}.json"
    [[ -f "$mfile" ]] || return 0
    jq -r '.environment // empty' "$mfile" 2>/dev/null
}

# Resolve the effective backup policy for a module.
#   $1 = module name (its config is CONFIG_DIR/<module>.json)
#   $2 = environment name override (optional; else module's .environment)
# Prints a JSON object. Exit 1 only on a hard read error (bad module name with
# no file AND no overrides is still resolvable from site defaults).
bc_resolve() {
    local module="$1" env_override="${2:-}"
    local site_file env_file mfile env_name

    site_file="$(_bc_site_file)"
    mfile="${CASCADE_CONFIG_DIR}/${module}.json"
    env_name="$(bc_module_environment "$module" "$env_override")"
    env_file="$(_bc_env_file "$env_name")"

    # Read each layer as JSON (or {} when the file/object is absent), then merge
    # in one jq pass so precedence is explicit and auditable.
    local site_json="{}" env_json="{}" mod_json="{}"
    [[ -n "$site_file" ]] && site_json="$(jq -c '.backup // {}' "$site_file" 2>/dev/null || echo '{}')"
    [[ -n "$env_file" ]] && env_json="$(jq -c '. as $e | ($e.backup // {}) + {dataResidency: ($e.dataResidency // null)}' "$env_file" 2>/dev/null || echo '{}')"
    [[ -f "$mfile" ]] && mod_json="$(jq -c '.backup // {}' "$mfile" 2>/dev/null || echo '{}')"

    # site_json/env_json/mod_json are always valid JSON ({} when absent).
    jq -n \
        --argjson site "$site_json" \
        --argjson env "$env_json" \
        --argjson mod "$mod_json" \
        --arg module "$module" \
        --arg environment "${env_name:-}" \
        '
        ($site.defaultRetention // "7y")                                  as $siteRet |
        (if ($env.retention // "") == "" then $siteRet else $env.retention end)  as $envRet |
        (if ($mod.retention // "") == "" then $envRet else $mod.retention end)   as $ret |
        (($env.residency // $env.dataResidency) // "eu-only")             as $residency |
        (if ($mod.enabled == false) then false else true end)            as $enabled |
        {
          module:    $module,
          environment: (if $environment == "" then null else $environment end),
          enabled:   $enabled,
          retention: $ret,
          residency: $residency,
          schedule:  ($env.schedule // null),
          target:    ($site.target // null),
          offsite:   ($site.offsite // null),
          exclude:   ($mod.exclude // [])
        }
        '
}

# True (0) if <module> declares dependsOn backup:vm (i.e. is wired into the
# shared PBS job). Used by status to show the wiring state alongside the policy.
bc_module_in_pbs_job() {
    local mfile="${CASCADE_CONFIG_DIR}/$1.json"
    [[ -f "$mfile" ]] || return 1
    jq -e '(.dependsOn // []) | index("backup:vm")' "$mfile" >/dev/null 2>&1
}

# List deployed module config basenames (without .json), skipping known
# non-module config files (site/zones/backup/remote-/external-/configuration).
bc_list_modules() {
    local f b
    shopt -s nullglob
    for f in "${CASCADE_CONFIG_DIR}"/*.json; do
        b="$(basename "$f" .json)"
        case "$b" in
            site|zones|backup|configuration|module-catalog) continue ;;
            remote-*|external-*) continue ;;
        esac
        printf '%s\n' "$b"
    done
    shopt -u nullglob
}
