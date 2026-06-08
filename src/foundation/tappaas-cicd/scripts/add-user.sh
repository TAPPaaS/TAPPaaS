#!/usr/bin/env bash
#
# TAPPaaS — add (or update) a person's single Authentik login and assign roles
# (ADR-006 Phase 3, issue #56). Idempotent: re-running adds roles without
# removing existing ones.
#
# One person = one Authentik user; their ROLES are group memberships. Roles are
# scoped to a variant (client) — except `installer`, which is always global.
#
#   Role               Group it maps to            Scope
#   installer          tappaas-installers          global (variant ignored)
#   admin              <scope>-admins              default or --variant
#   user               <scope>-users              default or --variant
#   module-admin:<m>   <scope>-<m>-admins          default or --variant
#
# where <scope> = `tappaas` for the default variant, else the variant name.
#
# Credential delivery: tries a one-time recovery/enrollment LINK (emailed once
# SMTP is configured — deferred to a separate issue). If the brand has no
# recovery flow yet, falls back to setting and PRINTING a generated password.
#
# Usage:
#   add-user.sh <username> --email <addr> [--name "Full Name"] \
#               [--variant <name>] [--role <role> ...] [--no-credential]
#
# Examples:
#   add-user.sh lars --email lars@example.org                      # default user
#   add-user.sh lars --email lars@example.org --role admin
#   add-user.sh jane --email jane@acme.org --variant acme --role user
#   add-user.sh jane --email jane@acme.org --variant acme --role module-admin:nextcloud
#   add-user.sh root --email root@example.org --role installer
#
# Override the CLI for testing: AUTHENTIK_MANAGER="/path/to/wrapper" add-user.sh …

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
ROLES_ENSURE="${ROLES_ENSURE:-/home/tappaas/bin/roles-ensure.sh}"

USERNAME=""
EMAIL=""
DISPLAY_NAME=""
VARIANT=""
NO_CREDENTIAL=0
declare -a ROLES=()

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)         EMAIL="${2:-}"; shift 2 ;;
        --name)          DISPLAY_NAME="${2:-}"; shift 2 ;;
        --variant)       VARIANT="${2:-}"; shift 2 ;;
        --role)          ROLES+=("${2:-}"); shift 2 ;;
        --no-credential) NO_CREDENTIAL=1; shift ;;
        --help|-h)       usage 0 ;;
        -*)              error "unknown option: $1"; usage 1 ;;
        *)
            if [[ -z "${USERNAME}" ]]; then USERNAME="$1"; shift
            else error "unexpected argument: $1"; usage 1; fi
            ;;
    esac
done

[[ -n "${USERNAME}" ]] || { error "username is required"; usage 1; }
[[ -n "${EMAIL}" ]]    || { error "--email is required"; usage 1; }
[[ ${#ROLES[@]} -gt 0 ]] || ROLES=("user")        # default to a basic user

scope_prefix() { [[ -z "$1" ]] && echo "tappaas" || echo "$1"; }
PREFIX="$(scope_prefix "${VARIANT}")"

main() {
    [[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found at ${CONFIG_FILE}"

    # Validate a named variant is registered (the default "" always exists).
    if [[ -n "${VARIANT}" ]]; then
        jq -e --arg v "${VARIANT}" '(.tappaas.variants // {}) | has($v)' "${CONFIG_FILE}" >/dev/null \
            || die "variant '${VARIANT}' is not registered (run: variant-manager.sh add ${VARIANT} …)"
    fi

    ${AUTHENTIK_MANAGER} test >/dev/null 2>&1 \
        || die "authentik-manager cannot reach Authentik (check ~/.authentik-credentials.txt)"

    # Make sure the scope's base role groups exist before we assign them.
    if [[ -x "${ROLES_ENSURE}" ]]; then
        "${ROLES_ENSURE}" --variant "${VARIANT}" >/dev/null \
            || warn "roles-ensure failed — assigning to groups assumed to already exist"
    fi

    # Resolve each role to a group name (creating opt-in module-admin groups).
    local role module group
    declare -a ROLE_GROUPS=()
    for role in "${ROLES[@]}"; do
        case "${role}" in
            installer)
                [[ -z "${VARIANT}" ]] || warn "role 'installer' is global — ignoring --variant ${VARIANT} for it"
                group="tappaas-installers" ;;
            admin)
                group="${PREFIX}-admins" ;;
            user)
                group="${PREFIX}-users" ;;
            module-admin:*)
                module="${role#module-admin:}"
                [[ -n "${module}" ]] || die "role 'module-admin:' needs a module name (e.g. module-admin:nextcloud)"
                group="${PREFIX}-${module}-admins"
                # opt-in module-admin group — ensure it exists so we can assign it.
                ${AUTHENTIK_MANAGER} group-ensure "${group}" --parent "${PREFIX}" \
                    --attr "tappaas.variant=${VARIANT}" --attr "tappaas.role=module-admin" \
                    --attr "tappaas.module=${module}" >/dev/null ;;
            *)
                die "unknown role '${role}' (expected: installer|admin|user|module-admin:<module>)" ;;
        esac
        ROLE_GROUPS+=("${group}")
    done

    # Ensure the user + (additive) group membership.
    info "${BOLD}Adding/updating user '${USERNAME}'${CL} (scope '${VARIANT:-<default>}', roles: ${ROLES[*]})"
    local -a ensure_args=("user-ensure" "${USERNAME}" "--email" "${EMAIL}")
    [[ -n "${DISPLAY_NAME}" ]] && ensure_args+=("--name" "${DISPLAY_NAME}")
    for group in "${ROLE_GROUPS[@]}"; do ensure_args+=("--group" "${group}"); done
    ${AUTHENTIK_MANAGER} "${ensure_args[@]}"
    info "  ${GN}✓${CL} groups: ${ROLE_GROUPS[*]}"

    [[ "${NO_CREDENTIAL}" -eq 1 ]] && { info "  (credential setup skipped: --no-credential)"; return 0; }

    # Credential delivery: prefer a one-time link; fall back to a printed password.
    info "${BOLD}Credential${CL}"
    local link
    if link="$(${AUTHENTIK_MANAGER} user-recovery-link "${USERNAME}" 2>/dev/null)" && [[ -n "${link}" ]]; then
        info "  ${GN}✓${CL} one-time enrollment link (share with the user; expires per Authentik policy):"
        echo "    ${link}"
        info "  (once SMTP is configured this link is emailed automatically — ADR-006 / SMTP issue)"
    else
        warn "  no recovery flow on the brand yet — set an initial password instead:"
        ${AUTHENTIK_MANAGER} user-set-password "${USERNAME}" | sed 's/^/    /'
        info "  share the generated password over a secure channel; the user can change it after login"
    fi
}

main "$@"
