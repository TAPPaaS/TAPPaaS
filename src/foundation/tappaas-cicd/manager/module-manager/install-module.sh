#!/usr/bin/env bash
#
# TAPPaaS Module Installer with Dependency Management
#
# Installs a TAPPaaS module by validating its JSON configuration,
# checking that all declared dependencies are satisfied, calling
# each dependency's install-service.sh script, and then running
# the module's own install.sh.
#
# Usage: install-module.sh <module-name> [--variant <name>] [--<field> <value>]...
#
# Arguments:
#   module-name   Name of the module to install (must have a
#                 <module-name>.json in the current directory)
#
# Options:
#   --variant <name>   Install a variant of the module (see copy-update-json.sh)
#   --force            Re-run the installer against the existing deployment even
#                      if the module is already installed (skips the
#                      already-installed precondition; does NOT remove anything)
#   --reinstall        Delete the existing deployment first (delete-module.sh
#                      --force), then install fresh. Use when a previous install
#                      left a partial/broken deployment behind (issue #301).
#   --<field> <value>  Override a JSON field (passed to copy-update-json.sh)
#   -h, --help         Show this help message
#
# Examples:
#   install-module.sh vaultwarden
#   install-module.sh litellm --node tappaas2
#   install-module.sh openwebui --variant staging
#   install-module.sh openwebui --variant dev --zone0 srv-dev --vmid 315
#
# The script performs these steps:
#   1. Checks the module is not already installed (unless --force is given, or
#      --reinstall, which first deletes the existing deployment)
#   2. Copies and validates the module JSON config (variant-aware)
#   3. Checks that every dependsOn service is provided by an installed module
#   4. Validates that the module has service scripts for each service it provides
#   5. Iterates dependsOn and calls each provider's install-service.sh
#   6. Calls the module's own install.sh (if present in the module directory)
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <module-name> [--variant <name>] [--<field> <value>]...

Install a TAPPaaS module with dependency validation and service wiring.

Arguments:
    module-name              Name of the module (expects ./<module-name>.json)

Options:
    --environment <name>     Target environment (ADR-007 P5). Drives the VM name
                             (<module> in the default env, else <module>-<env>)
                             and zone0 (from config/environments/<env>.json →
                             network.zone). Foundation-tier modules may ONLY be
                             installed into 'mgmt'.
    --variant <name>         DEPRECATED alias for --environment (compat period).
                             --environment wins if both are given.
    --allow-fork             Permit a foundation-tier module from a non-official
                             source (tier/source lint override).
    --force                  Install even if the module already exists (re-runs
                             against the existing deployment; removes nothing)
    --reinstall              Delete the existing deployment first, then install
                             fresh (delete-module.sh --force, then install)
    --<field> <value>        Override a JSON field value
    -h, --help               Show this help message

Environment / zone resolution (ADR-007 P5):
    * --environment given          → use it.
    * else tier:foundation         → 'mgmt'.
    * else                         → the default environment (single non-mgmt
                                      env / site name); else today's behaviour.
    zone0: explicit .zone0 in the JSON wins; else the environment's network.zone
    (when the env file exists); else resolve_default_zone() (back-compat).

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} litellm --node tappaas2
    ${SCRIPT_NAME} nextcloud --environment foo
    ${SCRIPT_NAME} openwebui --variant staging
    ${SCRIPT_NAME} identity --force
    ${SCRIPT_NAME} homeassistant --reinstall
EOF
}

# ── Default-zone resolution (ADR-007 S6 N6) ───────────────────────────
#
# Resolve the zone for a module whose JSON declares no explicit zone0. The
# default zone is the TAPPaaS system's default-environment zone (= the system
# name <N>), NOT mgmt. Resolution order:
#
#   1. explicit .zone0 in the module JSON          (handled by the caller — wins)
#   2. site.json '.name'                           (when site.json exists AND that
#                                                    zone exists in zones.json)
#   3. the single non-mgmt environment's network.zone
#                                                  (when exactly one such env exists)
#   4. fall back to "mgmt" (today's behaviour)     (pre-cutover: no site.json /
#                                                    environments yet) — with a warn
#
# Echoes the resolved zone name. Reads only ${CONFIG_DIR}; never mutates state.
resolve_default_zone() {
    local zones_file="${CONFIG_DIR}/zones.json"
    local site_file="${CONFIG_DIR}/site.json"
    local env_dir="${CONFIG_DIR}/environments"

    # (2) site.json.name, when it names a zone that exists in zones.json.
    if [[ -f "$site_file" ]]; then
        local site_name
        site_name="$(jq -r '.name // empty' "$site_file" 2>/dev/null)"
        if [[ -n "$site_name" && "$site_name" != "mgmt" ]]; then
            if [[ -f "$zones_file" ]] && \
               jq -e --arg z "$site_name" 'has($z)' "$zones_file" >/dev/null 2>&1; then
                printf '%s\n' "$site_name"
                return 0
            fi
        fi
    fi

    # (3) exactly one non-mgmt environment → its network.zone.
    if [[ -d "$env_dir" ]]; then
        local f base zone count=0 only_zone=""
        for f in "$env_dir"/*.json; do
            [[ -e "$f" ]] || continue
            base="$(basename "$f" .json)"
            [[ "$base" == "mgmt" ]] && continue
            zone="$(jq -r '.network.zone // empty' "$f" 2>/dev/null)"
            [[ -n "$zone" ]] || continue
            count=$((count + 1))
            only_zone="$zone"
        done
        if [[ "$count" -eq 1 ]]; then
            printf '%s\n' "$only_zone"
            return 0
        fi
    fi

    # (4) pre-cutover fallback — preserve today's behaviour.
    warn "  No default zone resolvable (no site.json/zones.json match and not exactly one non-mgmt environment) — falling back to 'mgmt'. Set an explicit zone0, or bootstrap site.json + environments to enable default-zone placement." >&2
    printf '%s\n' "mgmt"
    return 0
}

# ── Environment helpers (ADR-007 P5) ──────────────────────────────────
#
# The default environment is the single non-mgmt environment / site name <N>.
# These helpers REUSE the same sources resolve_default_zone() uses (site.json
# '.name' and the single non-mgmt environments/*.json), so default-env and
# default-zone resolution stay unified — environment selection and zone
# selection cannot disagree.

# Echo the name of the default (non-mgmt) environment, or empty if none is
# resolvable. Resolution order mirrors resolve_default_zone():
#   1. site.json '.name'                 (when it names an existing env file, or
#                                          there is no environments dir yet)
#   2. the single non-mgmt environment   (when exactly one such env file exists)
resolve_default_environment() {
    local site_file="${CONFIG_DIR}/site.json"
    local env_dir="${CONFIG_DIR}/environments"

    # (1) site.json.name (the site/system name == default-env name per S6/N6).
    if [[ -f "$site_file" ]]; then
        local site_name
        site_name="$(jq -r '.name // empty' "$site_file" 2>/dev/null)"
        if [[ -n "$site_name" && "$site_name" != "mgmt" ]]; then
            printf '%s\n' "$site_name"
            return 0
        fi
    fi

    # (2) exactly one non-mgmt environment file → its name.
    if [[ -d "$env_dir" ]]; then
        local f base count=0 only=""
        for f in "$env_dir"/*.json; do
            [[ -e "$f" ]] || continue
            base="$(basename "$f" .json)"
            [[ "$base" == "mgmt" ]] && continue
            count=$((count + 1))
            only="$base"
        done
        if [[ "$count" -eq 1 ]]; then
            printf '%s\n' "$only"
            return 0
        fi
    fi

    # No default environment resolvable (pre-cutover / multi-env ambiguity).
    printf '%s\n' ""
    return 0
}

# Echo the zone for a given environment name, by reading
# environments/<env>.json → .network.zone. Echoes empty if the file is absent
# or declares no zone (caller falls back to resolve_default_zone for back-compat).
resolve_zone_for_environment() {
    local env="$1"
    local env_file="${CONFIG_DIR}/environments/${env}.json"
    [[ -f "$env_file" ]] || { printf '%s\n' ""; return 0; }
    jq -r '.network.zone // empty' "$env_file" 2>/dev/null
}

# True if a module config for <module> already exists in CONFIG_DIR (the
# installed marker). Used for the foundation single-instance guard — offline,
# config-only (never probes the cluster).
module_config_exists() {
    [[ -f "${CONFIG_DIR}/${1}.json" ]]
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate module name argument
    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    local module="$1"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Install: ${BL}${module}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # Parse options: extract --force/--reinstall (consumed here) and capture
    # --variant (needed for the early existence check). All other arguments are
    # passed through unchanged to copy-update-json.sh, which reads "$@" when
    # sourced.
    local force=false
    local reinstall=false
    local variant=""
    local environment=""
    local environment_explicit=false
    local allow_fork=false
    local -a passthru=()
    shift  # drop the module name; re-added below
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                ;;
            --reinstall)
                reinstall=true
                ;;
            --allow-fork)
                allow_fork=true
                ;;
            --environment)
                environment="${2:-}"
                environment_explicit=true
                if [[ $# -ge 2 ]]; then shift; fi
                ;;
            --variant)
                # Deprecated alias for --environment (compat). --environment
                # wins; only adopt the variant value if no --environment given.
                variant="${2:-}"
                if [[ $# -ge 2 ]]; then shift; fi
                ;;
            *)
                passthru+=("$1")
                ;;
        esac
        shift
    done

    # --environment wins over --variant. If only --variant was given, treat it
    # as the environment name (the deprecated alias) — but keep the old variant
    # registry path working by ALSO forwarding --variant when no --environment
    # was explicitly given (back-compat for registered variants).
    if [[ "${environment_explicit}" == false && -n "${variant}" ]]; then
        # Deprecated --variant alias → environment, registry-free P5 path.
        environment="${variant}"
        warn "  --variant is deprecated; treating '--variant ${variant}' as '--environment ${variant}' (ADR-007 P5)"
    fi
    # The legacy variant value is not used past this point — the P5 environment
    # path is registry-free. Keep it empty for the dependency-resolution helpers.
    variant=""

    # ── Step 0: Classify tier/source and resolve the target environment ──
    echo ""
    info "${BOLD}Step 0: Classify (tier/source) and resolve environment${CL}"

    # The authored module JSON in the module directory (cwd) is the source of
    # truth for tier (and any pinned source). Read it before copying anything.
    local source_json="./${module}.json"
    [[ -f "${source_json}" ]] || die "Source module config not found: ${source_json} (run install-module.sh from the module directory)"

    # Tier/source lint (ADR-007b). Foundation modules MUST be source:official
    # unless --allow-fork; community modules warn (non-fatal). The lint is the
    # authority on the enum values, so install fails fast on a bad classification.
    local lint_cmd="/home/tappaas/bin/validate-module-tier-source.sh"
    if [[ ! -x "${lint_cmd}" ]]; then
        # Fall back to the script alongside this one (e.g. when run from the repo
        # without the ~/bin symlinks installed).
        lint_cmd="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/validate-module-tier-source.sh"
    fi
    local -a lint_args=("${source_json}")
    [[ "${allow_fork}" == true ]] && lint_args+=("--allow-fork")
    if ! "${lint_cmd}" "${lint_args[@]}"; then
        die "tier/source lint failed for ${module} — fix the classification (or pass --allow-fork for a foundation fork)"
    fi

    local tier
    tier="$(jq -r '.tier // "app"' "${source_json}")"
    info "  tier=${BL}${tier}${CL}"

    # Environment resolution (ADR-007 P5):
    #   explicit --environment → use it; else tier:foundation → mgmt; else the
    #   default environment (single non-mgmt env / site name); else "" (back-compat,
    #   meaning "no environment selected" — behaves like a vanilla legacy install).
    local default_env
    default_env="$(resolve_default_environment)"
    if [[ -z "${environment}" ]]; then
        if [[ "${tier}" == "foundation" ]]; then
            environment="mgmt"
        elif [[ -n "${default_env}" ]]; then
            environment="${default_env}"
        else
            environment=""   # nothing resolvable → legacy/no-env path
        fi
    fi
    if [[ -n "${environment}" ]]; then
        info "  environment=${BL}${environment}${CL} (default environment: ${default_env:-<none>})"
    else
        info "  no environment selected — legacy/no-env install (back-compat)"
    fi

    # Foundation-tier constraints: mgmt-only + single-instance (offline guard).
    if [[ "${tier}" == "foundation" ]]; then
        if [[ -n "${environment}" && "${environment}" != "mgmt" ]]; then
            die "Foundation modules can only be installed in the 'mgmt' environment (got '${environment}')"
        fi
        if module_config_exists "${module}" && [[ "${force}" != true && "${reinstall}" != true ]]; then
            die "Foundation module '${module}' is already installed (single-instance). Use --reinstall to replace, or --force to re-run the installer."
        fi
    fi

    # Compute the effective module name and VM name from the environment.
    # No suffix when: no environment selected (legacy), the environment IS the
    # default environment, or it is 'mgmt' (foundation default). Otherwise the
    # name is <module>-<environment>.
    local effective_module="${module}"
    local computed_vmname="${module}"
    if [[ -n "${environment}" \
          && "${environment}" != "mgmt" \
          && ( -z "${default_env}" || "${environment}" != "${default_env}" ) ]]; then
        effective_module="${module}-${environment}"
        computed_vmname="${module}-${environment}"
    fi
    info "  effective module name = ${BL}${effective_module}${CL}; vmname = ${BL}${computed_vmname}${CL}"

    # ── Step 1: Check module not already installed ───────────────────
    echo ""
    info "${BOLD}Step 1: Check module not already installed${CL}"

    # The installed-marker is the config JSON in CONFIG_DIR, which Step 2
    # overwrites — so check before copying. Environment builds use the suffixed
    # name (<module>-<environment>.json).
    local precheck_module="${effective_module}"

    if [[ "${reinstall}" == true ]]; then
        # --reinstall: tear down any existing deployment first, then install
        # fresh. Decide on config presence (not module_exists, which also probes
        # the cluster) so a partial install — config written but VM/services left
        # half-wired (issue #301) — is still fully cleaned up before re-install.
        if [[ -f "${CONFIG_DIR}/${precheck_module}.json" ]]; then
            warn "  '${precheck_module}' already deployed — deleting it first (--reinstall)"
            /home/tappaas/bin/delete-module.sh "${precheck_module}" --force \
                || die "Pre-reinstall delete of '${precheck_module}' failed — aborting before re-install"
            info "  ${GN}✓${CL} '${precheck_module}' deleted — proceeding with a fresh install"
        else
            info "  ${GN}✓${CL} '${precheck_module}' is not installed — --reinstall proceeds as a normal install"
        fi
    elif module_exists "${precheck_module}"; then
        if [[ "${force}" == true ]]; then
            warn "  '${precheck_module}' is already installed — continuing anyway (--force)"
        else
            die "Module '${precheck_module}' is already installed. Run 'delete-module.sh ${precheck_module}' first, pass --reinstall to delete and re-install fresh, or pass --force to re-run the installer against the existing deployment."
        fi
    else
        info "  ${GN}✓${CL} '${precheck_module}' is not yet installed"
    fi

    # ── Step 2: Copy JSON config and validate ────────────────────────
    echo ""
    info "${BOLD}Step 2: Copy and validate module configuration${CL}"

    # Build the copy-update-json argument vector. When an environment is
    # selected we drive the effective name + vmname through --environment /
    # --default-environment / --vmname (ADR-007 P5 — registry-free, distinct
    # from the legacy --variant path). When no environment is selected we keep
    # the plain legacy behaviour (back-compat).
    local -a cuj_args=("${module}")
    if [[ -n "${environment}" ]]; then
        cuj_args+=("--environment" "${environment}")
        [[ -n "${default_env}" ]] && cuj_args+=("--default-environment" "${default_env}")
        # Computed vmname only when the operator did not pass an explicit one.
        if [[ " ${passthru[*]-} " != *" --vmname "* ]]; then
            cuj_args+=("--vmname" "${computed_vmname}")
        fi
    fi
    cuj_args+=(${passthru[@]+"${passthru[@]}"})

    set -- "${cuj_args[@]}"
    . /home/tappaas/bin/copy-update-json.sh

    # Use effective module name reported by copy-update-json (authoritative).
    effective_module="${EFFECTIVE_MODULE:-${effective_module}}"
    if [[ "${effective_module}" != "${module}" ]]; then
        info "Environment active: effective module name is ${BL}${effective_module}${CL}"
    fi

    check_json "${CONFIG_DIR}/${effective_module}.json" || die "JSON validation failed for ${effective_module}"

    local module_json="${CONFIG_DIR}/${effective_module}.json"

    # zone0 resolution (ADR-007 P5, reconciled with S6 N6): precedence is
    #   1. explicit .zone0 in the module JSON / --zone0 override  (always wins)
    #   2. the target environment's network.zone                 (env file exists)
    #   3. resolve_default_zone()                                (back-compat)
    # The resolved value is written back into the module JSON so every downstream
    # consumer (the module's own install.sh, network provisioning) sees it.
    local zone0
    zone0=$(jq -r '.zone0 // empty' "${module_json}")
    if [[ -z "$zone0" && -n "${environment}" ]]; then
        zone0="$(resolve_zone_for_environment "${environment}")"
        if [[ -n "$zone0" ]]; then
            info "  zone0 not set — using environment '${environment}' zone ${BL}${zone0}${CL}"
            local _ztmp
            _ztmp="$(mktemp "${module_json}.XXXXXX")"
            jq --arg z "$zone0" '.zone0 = $z' "${module_json}" > "${_ztmp}" \
                && mv "${_ztmp}" "${module_json}" \
                || { rm -f "${_ztmp}"; die "Failed to write resolved zone0 into ${module_json}"; }
        fi
    fi
    if [[ -z "$zone0" ]]; then
        zone0="$(resolve_default_zone)"
        info "  zone0 not set — defaulting to ${BL}${zone0}${CL}"
        local _ztmp
        _ztmp="$(mktemp "${module_json}.XXXXXX")"
        jq --arg z "$zone0" '.zone0 = $z' "${module_json}" > "${_ztmp}" \
            && mv "${_ztmp}" "${module_json}" \
            || { rm -f "${_ztmp}"; die "Failed to write resolved zone0 into ${module_json}"; }
    fi
    if [[ -n "$zone0" ]]; then
        validate_zone_active "$zone0" || die "Zone validation failed — install aborted before any resources were created"
    fi

    # Announce the OPNsense firewall alias this vmname will get (#300, #316).
    # Long names are hashed to a safe 32-char alias rather than rejected, so this
    # only warns when hashing applies — it never blocks the install.
    local vmname_check
    vmname_check=$(jq -r '.vmname // empty' "${module_json}")
    [[ -n "${vmname_check}" ]] && validate_module_alias_name "${vmname_check}"

    # ── Step 3: Validate dependencies ────────────────────────────────
    echo ""
    info "${BOLD}Step 3: Validate dependencies${CL}"

    local depends_on
    depends_on=$(read_module_config "${effective_module}" | jq -r '.dependsOn // [] | .[]' 2>/dev/null)

    # A module is either VM-backed or container-backed, never both (issue #203).
    if read_module_config "${effective_module}" | jq -e '(.dependsOn // []) as $d
              | (($d | index("cluster:vm")) != null)
                and (($d | index("cluster:lxc")) != null)' >/dev/null 2>&1; then
        die "Module '${effective_module}' declares both cluster:vm and cluster:lxc in dependsOn — choose one (a guest is a VM or a container, not both)"
    fi

    local dep_errors=0
    if [[ -z "${depends_on}" ]]; then
        info "  No dependencies declared"
    else
        for dep in ${depends_on}; do
            if check_service_available "${dep}" "install-service.sh" "${variant}"; then
                info "  ${GN}✓${CL} ${dep}"
            else
                dep_errors=$((dep_errors + 1))
            fi
        done
    fi

    if [[ "${dep_errors}" -gt 0 ]]; then
        die "${dep_errors} dependency check(s) failed — cannot install ${module}"
    fi

    # ── Step 4: Validate provided services ───────────────────────────
    echo ""
    info "${BOLD}Step 4: Validate service scripts${CL}"

    local module_dir
    module_dir="$(pwd)"
    ensure_scripts_executable "${module_dir}"

    if ! validate_provided_services "${module_dir}" "${module_json}"; then
        die "Module service validation failed"
    fi

    local provides
    provides=$(read_module_config "${effective_module}" | jq -r '.provides // [] | .[]' 2>/dev/null)
    if [[ -z "${provides}" ]]; then
        info "  Module does not provide any services"
    else
        for svc in ${provides}; do
            info "  ${GN}✓${CL} provides: ${svc}"
        done
    fi

    # ── Step 5: Call dependency install-service.sh scripts ───────────
    echo ""
    info "${BOLD}Step 5: Call dependency service installers${CL}"

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to call"
    else
        for dep in ${depends_on}; do
            # Resolve the provider honoring variant preference, identically to the
            # Step 3 availability check, so a variant install calls the variant
            # provider's install-service.sh (#292).
            local provider_module
            provider_module="$(resolve_provider_module "${dep%%:*}" "${variant}")"
            local service_name="${dep##*:}"
            local provider_dir

            provider_dir=$(get_module_dir "${provider_module}")
            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/install-service.sh"

            info "  Calling ${BL}${dep}${CL} install-service.sh for module '${effective_module}'..."
            "${svc_script}" "${effective_module}" || die "Service installer failed: ${dep}"
            info "  ${GN}✓${CL} ${dep} install-service completed"
        done
    fi

    # ── Step 6: Call the module's own install.sh ─────────────────────
    echo ""
    info "${BOLD}Step 6: Run module install.sh${CL}"

    if [[ -x "./install.sh" ]]; then
        info "  Running ${module}/install.sh for '${effective_module}'..."
        ./install.sh "${effective_module}" || die "Module install.sh failed"
        info "  ${GN}✓${CL} Module install.sh completed"
    else
        info "  No install.sh found in module directory — skipping"
    fi

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Module '${effective_module}' installed successfully     ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

main "$@"
